#!/bin/zsh
cd "$(dirname "$0")"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

echo "Запуск QuizPlease SPB app..."

PORT=$(/usr/bin/ruby -rsocket -e '
  p = 4567
  40.times do
    begin
      s = TCPServer.new("127.0.0.1", p)
      s.close
      puts p
      exit
    rescue Errno::EADDRINUSE
      p += 1
    end
  end
  puts p
')

PORT="$PORT" ruby server.rb &
SERVER_PID=$!
sleep 2
open "http://127.0.0.1:$PORT"
wait $SERVER_PID
