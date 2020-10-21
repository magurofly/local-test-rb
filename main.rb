require "thread"
require "securerandom"
require "json"
require "webrick"

def main
  server = WEBrick::HTTPServer.new({
    DocumentRoot: "./www/",
    BindAdress: "127.0.0.1",
    Port: 13333,
  })

  init_server(server)

  trap(:INT) do
    server.shutdown
  end

  server.start
end

def init_server(server)
  @processes = {}
  @wait_queue = Thread::Queue.new

  server.mount_proc("/submit") do |req, res|
    res.content_type = "application/json"

    unless req.request_method === "POST"
      res.body = error_json("method must be POST")
    end

    id = generate_id

    @processes[id] = JSON.parse(req.body)
    @wait_queue.enq id

    res.body = JSON.generate({
      status: "success",
      id: id,
    })
  end

  @pool = 5.times.map do
    Thread.fork do
      loop do
        id = @wait_queue.deq
        data = @processes[id]
        
      end
    end
  end
end

def generate_id
  id = nil
  begin
    id = SecureRandom.uuid
  end until @processes.key? id
  id
end

def error_json(reason)
  JSON.generate({
    status: "error",
    message: reason,
  })
end


main