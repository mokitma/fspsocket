#!/usr/bin/env ruby
#
# Simple echo server
#
require 'rubygems'
require 'fspsocket'

trap('INT') {
  $sock.close
  exit 
}  

$sock = FSPSocket.new
puts $sock.id
$sock.received {|*data|
  puts "\"#{data[1].strip!}\" from a client<#{data[0]}>"
  $sock.puts("#{data[1]} from a server<#{$sock.id}>")
}

STDIN.gets
$sock.close
