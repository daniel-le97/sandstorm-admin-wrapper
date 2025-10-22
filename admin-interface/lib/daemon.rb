require 'file-tail'
require_relative 'rcon-client'
require_relative 'server-monitor'
require_relative 'server-updater'
require_relative 'subprocess'

include Process

class SandstormServerDaemon
  attr_accessor :config
  attr_accessor :executable
  attr_accessor :server_root_dir
  attr_accessor :arguments
  attr_accessor :rcon_ip
  attr_accessor :rcon_port
  attr_accessor :rcon_pass
  attr_accessor :player_feed
  attr_accessor :steam_api_key
  attr_reader :frozen_config
  attr_reader :name
  attr_reader :id
  attr_reader :active_game_port
  attr_reader :active_rcon_port
  attr_reader :active_query_port
  attr_reader :active_rcon_pass
  attr_reader :buffer
  attr_reader :rcon_buffer
  attr_reader :chat_buffer
  attr_reader :rcon_client
  attr_reader :game_pid
  attr_reader :threads
  attr_reader :monitor
  attr_reader :log_file
  attr_reader :rcon_listening

  def initialize(config, daemons, mutex, rcon_client, server_buffer, rcon_buffer, chat_buffer, steam_api_key: '')
    @config = config
    @name = @config['server-config-name']
    @id = @config['id']
    @daemons = daemons
    @daemons_mutex = mutex
    @monitor_mutex = Mutex.new
    @rcon_ip = '127.0.0.1'
    @buffer = server_buffer
    @rcon_buffer = rcon_buffer
    @chat_buffer = chat_buffer
    @rcon_client = rcon_client
    @rcon_listening = false
    @game_pid = nil
    @monitor = nil
    @threads = {}
    @buffer[:persistent] = true
    @rcon_buffer[:persistent] = true
    @chat_buffer[:persistent] = true
    @chat_buffer[:filters] = [
      Proc.new do |line|
        line.gsub!(/\x1b\[[0-9;]*m/, '') # Remove color codes
        line.gsub!(/^(\d{4}\/\d{2}\/\d{2}) (\d{2}:\d{2}:\d{2}).*TX >>\) say/, '\1 \2 ADMIN:') # Cut down RCON messages (TX)
        line.gsub!(/^\[(\d{4})\.(\d{2})\.(\d{2})-(\d{2}).(\d{2}).(\d{2}).*LogChat: Display: /, '\1/\2/\3 \4:\5:\6 ') # Cut down server log messages (RX)
      end
    ]
    @buffer[:filters] = [
      Proc.new do |line|
        line.gsub!(/\x1b\[[0-9;]*m/, '') # Remove color codes
        line.prepend "#{get_server_id} | "
      end
    ]
    @rcon_buffer[:filters] = [
      Proc.new { |line| line.prepend "#{get_server_id} | " }
    ]
    @log_file = nil
    @player_feed = []
    @admin_ids = nil
    @steam_api_key = steam_api_key
    @exit_requested = false
    start_daemon
    log "Daemon initialized"
  end

  def log(message, exception=nil, level: nil)
    super("#{get_server_id} | #{message}", exception, level: level) # Call the log function created by logger
  end

  def get_server_id
    conf = @frozen_config || @config
    "[PID #{@game_pid || '(N/A)'} Ports #{[conf['server_game_port'], conf['server_query_port'], conf['server_rcon_port']].join(',')}]"
  end

  def server_running?
    if @game_pid.nil?
      return false
    end
    Process.kill(0, @game_pid)
    true
  rescue Errno::ESRCH
    false
  end

  def do_pre_update_warning(sleep_length: 5)
    log "Sending restart warning to server", level: :info
    message = 'say This server is restarting in 5 seconds to apply a new server update.'
    message << ' This may take some time.' if WINDOWS # Since we have to stop the server before downloading the update
    do_blast_message(message)
    sleep sleep_length
  rescue => e
    log "Error while trying to message players", e
  end

  def do_blast_message(message, amount: 3, interval: 0.2)
    amount.times do |i|
      do_send_rcon message
      sleep interval unless i + 1 == amount
    end
  end

  def is_sandstorm_admin?(steam_id)
    @admin_ids.include?(steam_id.to_s)
  end

  def do_send_rcon(command, host: nil, port: nil, pass: nil, buffer: nil, outcome_buffer: nil, no_rx: false)
    host ||= @rcon_ip
    port ||= @active_rcon_port || @config['server_rcon_port']
    port ||= @active_rcon_pass
    pass ||= @active_rcon_pass || @config['server_rcon_password']
    buffer ||= @rcon_buffer
    outcome_buffer ||= buffer
    log "Calling RCON client for command: #{command}"
    @rcon_client.send(host, port, pass, command, buffer: buffer, outcome_buffer: outcome_buffer, no_rx: no_rx)
  end

  def do_start_server_unprotected
    # log "start daemons mutex start"
    return if @exit_requested
    if server_running? || (@threads[:game_server] && @threads[:game_server].alive?)
      log "Server is already running. PID: #{@game_pid}"
      return
    end
    new_game_port = @config['server_game_port']
    if @active_game_port && @active_game_port != new_game_port
      # We need to move the daemon for future access
      log "Moving daemon #{@active_game_port} -> #{new_game_port}"
      former_tenant = @daemons[new_game_port]
      if former_tenant
        log "Stopping daemon #{former_tenant.name} using desired game port #{new_game_port}", level: :warn
        former_tenant.implode
      end
      @daemons[new_game_port] = @daemons.delete @active_game_port
    end
    log "Starting server", level: :info
    @server_started = false
    @server_failed = false
    @game_pid = nil
    @threads[:game_server] = get_game_server_thread
    # Keep the mutex lock until we see RCON listening or the server fails to start
    sleep 0.1 until (@game_pid && @rcon_listening) || @server_failed || @exit_requested
    msg = @game_pid ? "Server is starting. PID: #{@game_pid}" : "Server failed to start!"
    log msg
    nil
  end

  def do_stop_server_unprotected
    return unless server_running?
    log "Stopping server", level: :info
    # No need to do anything besides remove it from monitoring
    # We want the signal to be sent to the thread's subprocess
    # so that the thread has time to set the status/message in the buffer
    @server_thread_exited = false
    @threads.delete(:game_server)
    msg = kill_server_process
    log "Waiting for server thread to exit and clean up"
    sleep 0.2 until @server_thread_exited || @server_failed
    log "Server thread #{@server_failed ? "failed" : "exited and cleaned up"}"
    log msg
    nil
  end

  def do_start_server
    @exit_requested = false
    return Thread.new do
      @daemons_mutex.synchronize { do_start_server_unprotected }
    end
  end

  def do_restart_server
    log "Restarting server", level: :info
    return Thread.new do
      @daemons_mutex.synchronize do
        do_stop_server_unprotected
        do_start_server_unprotected
      end
    end
  end

  def do_stop_server
    @exit_requested = true
    return Thread.new do
      @daemons_mutex.synchronize { do_stop_server_unprotected }
    end
  end

  def process_kill_event(line)
    # Parse kill event from LogGameplayEvents
    # Format: PlayerName[SteamID, team X] killed VictimName[SteamID, team Y] with WeaponName
    # or: PlayerName[SteamID, team X] + AssistName[SteamID, team X] killed VictimName[SteamID, team Y] with WeaponName
    return unless line.match(/LogGameplayEvents.*killed/)
    
    begin
      # Extract the main kill information
      if line =~ /Display: (.+?) killed (.+?) with (.+?)$/
        killer_info = $1
        victim_info = $2
        weapon_raw = $3.strip
        
        # Clean weapon name (remove BP_ prefix and _C_ suffix with numbers)
        weapon_name = weapon_raw
          .gsub(/^BP_/, '')                    # Remove BP_ prefix
          .gsub(/_C_\d+$/, '')                 # Remove _C_12345 suffix
          .gsub(/_/, ' ')                      # Replace underscores with spaces
          .gsub(/^(Firearm|Projectile|Character|Weapon|Explosive)\s+/, '') # Remove common prefixes
          .strip                               # Clean up any extra whitespace
        
        # Check if it's an assist kill (contains +)
        has_assist = killer_info.include?('+')
        
        # Parse killer (first player before + or the only player)
        if has_assist
          killer_part = killer_info.split('+').first.strip
        else
          killer_part = killer_info.strip
        end
        
        # Extract killer steam ID and name
        if killer_part =~ /^(.+?)\[(\d{17}),\s*team\s*(\d+)\]$/
          killer_name = $1.strip
          killer_steam_id = $2
          killer_team = $3.to_i
        elsif killer_part =~ /^(.+?)\[INVALID,\s*team\s*(\d+)\]$/ || killer_part == '?'
          # Bot killed someone or self-kill - skip killer tracking
          killer_name = $1 ? $1.strip : '?'
          killer_steam_id = nil
          killer_team = $2 ? $2.to_i : -1
        else
          return # Can't parse killer
        end
        
        # Extract victim steam ID and name
        if victim_info =~ /^(.+?)\[(INVALID|(\d{17})),\s*team\s*(\d+)\]$/
          victim_name = $1.strip
          victim_steam_id = $3 # Will be nil for bots (INVALID)
          victim_team = $4.to_i
          is_bot_victim = $2 == 'INVALID'
        else
          return # Can't parse victim
        end
        
        # Check if it's a suicide
        is_suicide = (killer_steam_id == victim_steam_id)
        
        # Check if it's a teamkill
        is_teamkill = (killer_team == victim_team) && !is_suicide
        
        # Debug logging for suicide/teamkill detection
        if killer_steam_id == victim_steam_id
          log "Suicide detected: killer=#{killer_steam_id}, victim=#{victim_steam_id}, weapon=#{weapon_name}", level: :info
        end
        
        # Only track stats for real players (not bots)
        if killer_steam_id && killer_steam_id.match?(/^\d{17}$/)
          saved_killer = $config_handler.players[killer_steam_id]
          
          log "Processing kill event: killer=#{killer_name}(#{killer_steam_id}), victim=#{victim_name}(#{victim_steam_id || 'BOT'}), suicide=#{is_suicide}, teamkill=#{is_teamkill}, weapon=#{weapon_name}", level: :info
          
          if is_suicide
            # Track deaths for suicide
            saved_killer['total_deaths'] = saved_killer['total_deaths'].to_i + 1
            log "#{killer_name} committed suicide with #{weapon_name}", level: :debug
          elsif is_teamkill
            # Track teamkills separately - DON'T count as regular kills
            saved_killer['total_teamkills'] = saved_killer['total_teamkills'].to_i + 1
            log "#{killer_name} teamkilled #{victim_name} with #{weapon_name}", level: :debug
          else
            # Track regular kills (enemy kills only)
            saved_killer['total_kills'] = saved_killer['total_kills'].to_i + 1
            
            # Track weapon kills (only for enemy kills)
            saved_killer['weapons'] = {} if saved_killer['weapons'].nil?
            saved_killer['weapons'][weapon_name] = saved_killer['weapons'][weapon_name].to_i + 1
            
            log "#{killer_name} killed #{is_bot_victim ? 'bot' : victim_name} with #{weapon_name}", level: :debug
          end
        end
        
        # Track deaths for victim if they're a real player
        # DON'T count deaths from teamkills or suicides
        if victim_steam_id && victim_steam_id.match?(/^\d{17}$/) && !is_suicide && !is_teamkill
          saved_victim = $config_handler.players[victim_steam_id]
          saved_victim['total_deaths'] = saved_victim['total_deaths'].to_i + 1
        end
        
        # Save player data after updating kill/death stats
        $config_handler.write_player_info
        
      end
    rescue => e
      log "Failed to process kill event: #{line}", e
    end
  end

  def process_chat_command(line)
    # Parse chat command from LogChat
    # Format: LogChat: Display: PlayerName(SteamID) Global Chat: !command
    # Note: Line may have been filtered already, removing "LogChat: Display:"
    
    log "Chat line detected: #{line}", level: :info
    
    begin
      # The chat filter has already removed "LogChat: Display:" prefix
      # So the line format is now: 2025/10/15 18:58:53 PlayerName(SteamID) Global Chat: !command
      # OR original format: [2025.10.15-18.58.53:100][833]LogChat: Display: PlayerName(SteamID) Global Chat: !command
      
      # Match the format with or without "LogChat: Display:"
      match = line.match(/(.+?)\((\d{17})\)\s+Global Chat:\s*(.+)$/)
      if match
        log "Regex matched! Groups: #{match.captures.inspect}", level: :info
        
        player_name = match[1].strip
        # Remove timestamp if present (format: 2025/10/15 18:58:53 PlayerName)
        player_name.gsub!(/^\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2}:\d{2}\s+/, '')
        
        steam_id = match[2]
        message = match[3].strip
        
        # Only process if it's a command (starts with !)
        unless message.start_with?('!')
          log "Not a command (no ! prefix): #{message}", level: :info
          return
        end
        
        log "Chat command parsed - Player: #{player_name}, SteamID: #{steam_id}, Message: #{message}", level: :info
        
        # Get player data
        player = $config_handler.players[steam_id]
        if player.nil?
          log "Player data not found for SteamID: #{steam_id}", level: :warn
          return
        end
        
        log "Player data loaded: #{player.inspect}", level: :info
        
        # Process commands
        command = message.downcase.split.first
        log "Processing command: #{command}", level: :info
        
        case command
        when '!kdr'
          handle_kdr_command(player_name, steam_id, player)
        when '!stats'
          handle_stats_command(player_name, steam_id, player)
        when '!guns', '!weapons'
          handle_guns_command(player_name, steam_id, player)
        when '!top', '!leaderboard'
          handle_top_command(player_name, steam_id)
        else
          log "Unknown command: #{command}", level: :info
        end
      else
        log "Chat line did not match command regex: #{line}", level: :info
      end
    rescue => e
      log "Failed to process chat command: #{line}", e
    end
  end

  def handle_kdr_command(player_name, steam_id, player)
    log "=== KDR Command Handler ===", level: :info
    kills = player['total_kills'] || 0
    deaths = player['total_deaths'] || 0
    kd_ratio = deaths > 0 ? (kills.to_f / deaths).round(2) : kills.to_f
    
    log "Player stats - Kills: #{kills}, Deaths: #{deaths}, K/D: #{kd_ratio}", level: :info
    
    response = "#{player_name}: #{kills}K / #{deaths}D | K/D: #{kd_ratio}"
    log "Sending KDR response: #{response}", level: :info
    send_chat_message(response)
    log "KDR command completed for #{player_name}", level: :info
  end

  def handle_stats_command(player_name, steam_id, player)
    log "=== Stats Command Handler ===", level: :info
    total_score = player['total_score'] || 0
    total_duration = player['total_duration'] || 0
    
    log "Player stats - Score: #{total_score}, Duration: #{total_duration}s", level: :info
    
    # Calculate score per minute
    if total_duration > 0
      minutes = total_duration / 60.0
      score_per_min = (total_score / minutes).round(1)
    else
      score_per_min = 0.0
    end
    
    # Format playtime
    hours = total_duration / 3600
    mins = (total_duration % 3600) / 60
    
    response = "#{player_name}: Score: #{total_score} | Score/min: #{score_per_min} | Playtime: #{hours}h #{mins}m"
    log "Sending Stats response: #{response}", level: :info
    send_chat_message(response)
    log "Stats command completed for #{player_name}", level: :info
  end

  def handle_guns_command(player_name, steam_id, player)
    log "=== Guns Command Handler ===", level: :info
    weapons = player['weapons'] || {}
    
    log "Player weapons: #{weapons.inspect}", level: :info
    
    if weapons.empty?
      response = "#{player_name}: No weapon kills recorded yet"
    else
      # Get top 3 weapons
      top_weapons = weapons.sort_by { |_, kills| -kills }.take(3)
      
      weapon_list = top_weapons.map { |(weapon, kills)| "#{weapon}: #{kills}" }.join(' | ')
      response = "#{player_name}: #{weapon_list}"
    end
    
    log "Sending Guns response: #{response}", level: :info
    send_chat_message(response)
    log "Guns command completed for #{player_name}", level: :info
  end

  def handle_top_command(player_name, steam_id)
    log "=== Top Command Handler ===", level: :info
    
    # Get all players with valid stats
    players_with_stats = []
    
    $config_handler.players.each do |sid, player|
      next if player.nil?
      
      total_score = player['total_score'].to_i
      total_duration = player['total_duration'].to_i
      
      # Only include players with at least 1 minute of playtime
      next if total_duration < 60
      
      # Calculate score per minute
      minutes = total_duration / 60.0
      score_per_min = (total_score / minutes).round(1)
      
      players_with_stats << {
        name: player['display_name'] || player['name'] || 'Unknown',
        score_per_min: score_per_min,
        total_score: total_score,
        playtime_mins: minutes.round(0)
      }
    end
    
    log "Found #{players_with_stats.size} players with stats", level: :info
    
    if players_with_stats.empty?
      response = "Top Players: No stats available yet"
    else
      # Sort by score_per_min descending and take top 3
      top_players = players_with_stats.sort_by { |p| -p[:score_per_min] }.take(3)
      
      # Format: "Top 3: 1. PlayerName:12.5 | 2. Player2:10.3 | 3. Player3:8.7"
      leaderboard = top_players.each_with_index.map do |player, idx|
        "#{idx + 1}. #{player[:name]}:#{player[:score_per_min]}"
      end.join(' | ')
      
      response = "Top 3 (Score/min): #{leaderboard}"
    end
    
    log "Sending Top response: #{response}", level: :info
    send_chat_message(response)
    log "Top command completed", level: :info
  end

  def send_chat_message(message)
    log "=== Sending Chat Message ===", level: :info
    log "Message: #{message}", level: :info
    log "RCON Details - IP: #{@rcon_ip}, Port: #{@active_rcon_port}, Pass: #{@active_rcon_pass ? '[SET]' : '[NOT SET]'}", level: :info
    
    # Send message via RCON
    Thread.new do
      begin
        log "Executing RCON command: say #{message}", level: :info
        result = @rcon_client.send(@rcon_ip, @active_rcon_port, @active_rcon_pass, "say #{message}")
        log "RCON command result: #{result.inspect}", level: :info
        log "Chat message sent successfully", level: :info
      rescue => e
        log "Failed to send chat message: #{message}", e
      end
    end
  end

  def implode
    log "Daemon for server #{@name} (#{@config['id']}) imploding", level: :info
    @exit_requested = true
    @buffer.reset
    @buffer = nil
    @rcon_buffer.reset
    @rcon_buffer = nil
    Thread.new { @monitor.stop if @monitor }
    game_server_thread = @threads.delete :game_server
    kill_server_process
    game_server_thread.join unless game_server_thread.nil?
    @game_pid = nil
    @threads.keys.each do |thread_name|
      thread = @threads.delete thread_name
      thread.kill if thread.respond_to? :kill
    end
    log "Daemon for server #{@name} (#{@config['id']}) imploded", level: :info
  end

  def kill_server_process(signal: nil)
    signal = 'KILL' if signal.nil? # TERM can hang shutting down EAC. KILL doesn't, but might not disconnect players (instead they time out).
    return "Unable to send #{signal} (#{Signal.list[signal]}) signal to server; no known PID!" unless @game_pid
    return "Server isn't running!" unless server_running?
    begin
      Process.kill(signal, @game_pid)
    rescue Errno::ESRCH
    end
    msg = "Sent #{signal} (#{Signal.list[signal]}) signal to PID #{@game_pid}."
    log msg, level: :info
    msg
  end

  def create_monitor
    @monitor_mutex.synchronize do
      if @monitor.nil?
        Thread.new { @monitor = ServerMonitor.new('127.0.0.1', @active_query_port, @active_rcon_port, @active_rcon_pass, name: @name, rcon_buffer: @rcon_buffer, interval: 5, daemon_handle: self) }
      end
      sleep 0.5 while @monitor.nil? && !(@exit_requested)
    end
  end

  def run_game_server
    log "Applying config"
    @frozen_config = @config.dup
    $config_handler.apply_server_config_files @frozen_config
    @admin_ids = $config_handler.get_server_config_file_content(:admins_txt, @frozen_config['id']).split("\n").map { |l| l[/\d{17}/] }.compact
    executable = BINARY
    arguments = $config_handler.get_server_arguments(@frozen_config)
    @active_game_port = @frozen_config['server_game_port']
    @active_query_port = @frozen_config['server_query_port']
    @active_rcon_port = @frozen_config['server_rcon_port']
    @active_rcon_pass = @frozen_config['server_rcon_password']
    @log_file = $config_handler.get_log_file(@frozen_config['id'])
    log "Spawning game process: #{[executable, *arguments].inspect}", level: :info
    SubprocessRunner.run(
      [executable, *arguments],
      buffer: @buffer,
      pty: false,
      no_prefix: true,
      formatter: Proc.new { |output, _| WINDOWS ? "#{datetime} | #{output.chomp}" : output.chomp } # Windows doesn't have the timestamp, so we'll add our own to make it look nice.
    ) do |pid|
      @game_pid = pid
      log "Game process spawned. Starting self-monitoring after detecting RCON listening message.", level: :info
      @rcon_tail_thread = Thread.new do
        # last_modified_log_time = File.mtime(Dir[File.join(SERVER_LOG_DIR, '*.log')].sort_by{|f| File.mtime(f) }.last).to_i rescue 0
        # other_used_logs = @daemons.map { |_, daemon| daemon.log_file }
        # @rcon_buffer[:data] << "[PID: #{@game_pid} Game Port: #{@active_game_port}] Waiting to detect log file in use"
        log "Waiting to ensure log file is in use"
        earlier = Time.now.to_i
        loop do
          last_updated = File.mtime(@log_file).to_i
          break if last_updated > earlier
          sleep 0.5
        end
        log "Log file is in use. Proceeding with log tailing."
        begin
          File.open(@log_file) do |log|
            log.extend(File::Tail)
            log.interval = 0.1
            log.backward(0)
            last_line_was_rcon = false
            log.tail do |line|
              Thread.exit if @exit_requested
              next if line.nil?
              if line.include? 'LogRcon'
                last_line_was_rcon = true
                if line[/LogRcon: Error: Failed to create TcpListener at .* for rcon support/]
                  log "RCON failed to initialize: #{line}", level: :warn
                  kill_server_process
                elsif !@rcon_listening && line.include?('LogRcon: Rcon listening') && @monitor.nil?
                  @rcon_listening = true
                  log "RCON listening - Ending server start/stop lock", level: :info
                  create_monitor
                  Thread.new do
                    sleep 0.5 until @exit_requested || (@monitor && @monitor.all_green?)
                    if @exit_requested
                      kill_server_process
                      Thread.exit
                    end
                    log "Server is ready (RCON and Query connected)", level: :info
                    @server_started = true
                  end
                elsif line.include? 'SANDSTORM_ADMIN_WRAPPER'
                elsif line[/^[\[\]0-9.:-]+\[[0-9 ]+\]LogRcon: \d+.\d+.\d+.\d+:\d+ <<\s+banid (.*)/]
                  @daemons.reject{ |_,d| d == self || !d.rcon_listening || d.nil? }.each do |id, daemon|
                    begin
                      args = $1.split(' ')
                      if args.size > 0
                        args = $config_handler.parse_banid_args(args)
                        daemon.do_send_rcon("banid #{args.join(' ')} SANDSTORM_ADMIN_WRAPPER") # Give a custom suffix so we don't recursively unban
                      end
                    rescue => e
                      log "Failed to 'banid #{$1}' from server #{daemon.name} (#{id})"
                    end
                  end
                elsif line[/^[\[\]0-9.:-]+\[[0-9 ]+\]LogRcon: \d+.\d+.\d+.\d+:\d+ <<\s+unban (\d+)/]
                  # Allow unbans with master bans
                  $config_handler.unban_master($1)
                  log "Unbanning ID #{$1} from all servers (unban command detected)", level: :info
                  @daemons.reject{ |_,d| d == self || !d.rcon_listening || d.nil? }.each do |id, daemon|
                    begin
                      daemon.do_send_rcon("unban #{$1} SANDSTORM_ADMIN_WRAPPER") # Give a custom suffix so we don't recursively unban
                    rescue => e
                      log "Failed to unban #{$1} from server #{daemon.name} (#{id})"
                    end
                  end
                end
              elsif last_line_was_rcon
                if line =~ /^\[\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:/ || line =~ /^Log/
                  last_line_was_rcon = false
                end
              end
              if line.include? 'LogChat'
                @chat_buffer[:filters].each { |filter| filter.call(line) } # Remove color codes; add server ID
                @chat_buffer.synchronize { @chat_buffer.push line.chomp }
                # Process chat commands
                log "processing chat", level: :info
                process_chat_command(line)
              elsif last_line_was_rcon
                @buffer[:filters].each { |filter| filter.call(line) } # Remove color codes; add server ID
                @rcon_buffer.synchronize { @rcon_buffer.push line.chomp }
              elsif line.include?('LogGameplayEvents') && line.include?('killed')
                # Process kill/death events for player statistics
                process_kill_event(line)
              end
              # Detect game over and update stats for all connected players
              if line.include?('LogMapVoteManager: Display: Starting map vote')
                log "Game over detected in log. Updating stats for all connected players.", level: :info
                now = Time.now.to_i
                # You may need to get the current player list from the monitor or rcon_client
                if defined?(@monitor) && @monitor && @monitor.info[:rcon_players]
                  @monitor.info[:rcon_players].each do |player|
                    saved_player = $config_handler.players[player['steam_id']]
                    next if saved_player.nil? || player['steam_id'].nil? || player['steam_id'].empty?
                    # Add session score to total_score
                    if player['score']
                      session_score = player['score'].to_i
                      saved_player['total_score'] = saved_player['total_score'].to_i + session_score
                      log "[Game Over] Added #{session_score} to total_score for #{player['name']} (#{player['steam_id']})", level: :info
                    end
                    # Add session duration to total_duration
                    if saved_player['session_start']
                      session_duration = now - saved_player['session_start'].to_i
                      if session_duration > 0
                        saved_player['total_duration'] = saved_player['total_duration'].to_i + session_duration
                        log "[Game Over] Added #{session_duration}s to total_duration for #{player['name']} (#{player['steam_id']})", level: :info
                      end
                      saved_player['session_start'] = now # Reset session start for next match
                    end
                  end
                  $config_handler.write_player_info
                  log "[Game Over] Updated stats for all connected players.", level: :info
                end
              end
            end
          end
        rescue EOFError
        rescue => e
          log "Error in RCON tail thread!", e
          raise e
        ensure
          log "RCON tail thread stopped"
        end
      end
      log "RCON tailing thread started."
    end
    log 'Game process exited', level: :info
  ensure
    @rcon_tail_thread.kill rescue nil
  end

  def get_game_server_thread
    Thread.new do
      if !@exit_requested
        run_game_server
      end
    rescue => e
      @server_failed = true
      log "Game server failed", e
      Thread.new { @monitor.stop if @monitor }
      @threads.delete :game_server unless @server_started # If we can't even start the server, don't keep trying
      kill_server_process
    ensure
      @server_thread_exited = true
      begin
        @monitor.stop unless @monitor.nil?
        @monitor = nil
        @game_pid = nil
        @log_file = nil
        @rcon_listening = false
        socket = @rcon_client.sockets["127.0.0.1:#{@active_rcon_port}"]
        @rcon_client.delete_socket(socket) unless socket.nil?
      rescue => e
        log "Error while cleaning up game server thread", e
      end
      log "Game server thread exiting"
    end
  end

  def start_daemon(thread_check_interval: 2)
    @daemon_thread = Thread.new do
      while true
        while @threads.empty? || @threads.values.all?(&:alive?)
          sleep thread_check_interval
        end
        dead_threads = @threads.select { |_, t| !t.alive? }.keys
        log "Dead daemon thread(s) detected: #{dead_threads.join(' ')}"
        dead_threads.each do |key|
          if @threads[key]
            log "Starting #{key} thread", level: :info
            @threads[key] = public_send("get_#{key.to_s}_thread")
          end
        end
        sleep thread_check_interval
      end
    rescue => e
      log "Error in daemon's self-monitoring thread", e
      raise
    end
  end
end
