require 'fspsocket'

trap('INT') {
  $sock.close
  exit 
}

if ARGV.length == 0
  puts "Usage: #{$0} server_id"
  exit 1
end

def send_line
  print "> "
  STDOUT.flush
  line = STDIN.gets
  $sock.puts(line)
end

$sock = FSPSocket.open(ARGV[0]){|rh| 
  puts "sock: #{$sock.id}"
  rh.call {|*data|
    puts "#{data[1]}"
    send_line
  }
  send_line
}

loop do
  Thread.pass
end
$sock.close
