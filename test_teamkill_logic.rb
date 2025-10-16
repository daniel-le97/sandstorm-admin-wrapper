#!/usr/bin/env ruby

# Test teamkill tracking logic

# Mock player data
players = {
  "76561198995742987" => {
    "name" => "ArmoredBear",
    "total_kills" => 0,
    "total_deaths" => 0,
    "total_teamkills" => 0,
    "weapons" => {}
  },
  "76561198995742988" => {
    "name" => "PlayerTwo",
    "total_kills" => 0,
    "total_deaths" => 0,
    "total_teamkills" => 0,
    "weapons" => {}
  }
}

def process_kill(killer_steam_id, killer_name, killer_team, victim_steam_id, victim_name, victim_team, weapon_name, players)
  is_suicide = (killer_steam_id == victim_steam_id)
  is_teamkill = (killer_team == victim_team) && !is_suicide
  is_bot_victim = victim_steam_id.nil?
  
  # Track killer stats
  if killer_steam_id && killer_steam_id.match?(/^\d{17}$/)
    saved_killer = players[killer_steam_id]
    
    if is_suicide
      saved_killer['total_deaths'] += 1
      puts "  → Suicide: #{killer_name} +1 death"
    elsif is_teamkill
      saved_killer['total_teamkills'] += 1
      puts "  → Teamkill: #{killer_name} +1 teamkill (NO regular kill)"
    else
      saved_killer['total_kills'] += 1
      saved_killer['weapons'][weapon_name] ||= 0
      saved_killer['weapons'][weapon_name] += 1
      puts "  → Regular kill: #{killer_name} +1 kill with #{weapon_name}"
    end
  end
  
  # Track victim stats
  if victim_steam_id && victim_steam_id.match?(/^\d{17}$/) && !is_suicide && !is_teamkill
    saved_victim = players[victim_steam_id]
    saved_victim['total_deaths'] += 1
    puts "  → Victim: #{victim_name} +1 death"
  elsif is_teamkill
    puts "  → Teamkill victim: #{victim_name} gets NO death"
  end
end

puts "Testing Teamkill Logic"
puts "=" * 60
puts ""

# Test 1: Regular enemy kill
puts "Test 1: Player kills enemy player"
process_kill("76561198995742987", "ArmoredBear", 1, "76561198995742988", "PlayerTwo", 2, "M4A1", players)
puts "  ArmoredBear: K=#{players["76561198995742987"]["total_kills"]}, D=#{players["76561198995742987"]["total_deaths"]}, TK=#{players["76561198995742987"]["total_teamkills"]}"
puts "  PlayerTwo: K=#{players["76561198995742988"]["total_kills"]}, D=#{players["76561198995742988"]["total_deaths"]}, TK=#{players["76561198995742988"]["total_teamkills"]}"
puts ""

# Test 2: Teamkill
puts "Test 2: Player teamkills teammate"
process_kill("76561198995742987", "ArmoredBear", 1, "76561198995742988", "PlayerTwo", 1, "M4A1", players)
puts "  ArmoredBear: K=#{players["76561198995742987"]["total_kills"]}, D=#{players["76561198995742987"]["total_deaths"]}, TK=#{players["76561198995742987"]["total_teamkills"]}"
puts "  PlayerTwo: K=#{players["76561198995742988"]["total_kills"]}, D=#{players["76561198995742988"]["total_deaths"]}, TK=#{players["76561198995742988"]["total_teamkills"]}"
puts ""

# Test 3: Suicide
puts "Test 3: Player commits suicide"
process_kill("76561198995742987", "ArmoredBear", 1, "76561198995742987", "ArmoredBear", 1, "Frag", players)
puts "  ArmoredBear: K=#{players["76561198995742987"]["total_kills"]}, D=#{players["76561198995742987"]["total_deaths"]}, TK=#{players["76561198995742987"]["total_teamkills"]}"
puts ""

# Test 4: Kill bot
puts "Test 4: Player kills bot"
process_kill("76561198995742987", "ArmoredBear", 1, nil, "Bot", 2, "AKM", players)
puts "  ArmoredBear: K=#{players["76561198995742987"]["total_kills"]}, D=#{players["76561198995742987"]["total_deaths"]}, TK=#{players["76561198995742987"]["total_teamkills"]}"
puts ""

puts "=" * 60
puts "Final Stats:"
puts ""
puts "ArmoredBear:"
puts "  Kills: #{players["76561198995742987"]["total_kills"]} (should be 2: 1 enemy + 1 bot)"
puts "  Deaths: #{players["76561198995742987"]["total_deaths"]} (should be 1: suicide)"
puts "  Teamkills: #{players["76561198995742987"]["total_teamkills"]} (should be 1)"
puts "  Weapons: #{players["76561198995742987"]["weapons"].inspect}"
puts ""
puts "PlayerTwo:"
puts "  Kills: #{players["76561198995742988"]["total_kills"]} (should be 0)"
puts "  Deaths: #{players["76561198995742988"]["total_deaths"]} (should be 1: only enemy kill, NOT teamkill)"
puts "  Teamkills: #{players["76561198995742988"]["total_teamkills"]} (should be 0)"
puts ""

# Verify
expected = {
  "ArmoredBear" => { kills: 2, deaths: 1, teamkills: 1 },
  "PlayerTwo" => { kills: 0, deaths: 1, teamkills: 0 }
}

success = true
if players["76561198995742987"]["total_kills"] != expected["ArmoredBear"][:kills]
  puts "❌ FAILED: ArmoredBear kills incorrect"
  success = false
end
if players["76561198995742987"]["total_deaths"] != expected["ArmoredBear"][:deaths]
  puts "❌ FAILED: ArmoredBear deaths incorrect"
  success = false
end
if players["76561198995742987"]["total_teamkills"] != expected["ArmoredBear"][:teamkills]
  puts "❌ FAILED: ArmoredBear teamkills incorrect"
  success = false
end
if players["76561198995742988"]["total_deaths"] != expected["PlayerTwo"][:deaths]
  puts "❌ FAILED: PlayerTwo deaths incorrect (should NOT count teamkill death)"
  success = false
end

if success
  puts "✅ All tests passed!"
else
  puts "❌ Some tests failed"
end
