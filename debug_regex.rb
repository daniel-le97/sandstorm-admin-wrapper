#!/usr/bin/env ruby

test_line = '2025/10/15 18:58:53 ArmoredBear(76561198995742987) Global Chat: !kdr'

puts "Testing line: #{test_line}"
puts ""

# Try different regex patterns
regexes = [
  /(.+?)\((\d{17})\)\s+Global Chat:\s*(.+)$/,
  /(.+)\((\d{17})\)\s+Global Chat:\s*(.+)$/,
  /(\w+)\((\d{17})\)\s+Global Chat:\s*(.+)$/,
  /\s+(\w+)\((\d{17})\)\s+Global Chat:\s*(.+)$/,
]

regexes.each_with_index do |regex, i|
  puts "Pattern #{i+1}: #{regex.inspect}"
  if test_line =~ regex
    puts "  ✓ MATCH!"
    puts "    $1 (player): #{$1}"
    puts "    $2 (steam_id): #{$2}"
    puts "    $3 (message): #{$3}"
  else
    puts "  ✗ NO MATCH"
  end
  puts ""
end
