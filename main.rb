# [filename, build, run]
LANGS = {

}

require "thread"
require "securerandom"
require "json"
require "webrick"
require "tmpdir"

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

ProcessData = Struct.new(:request, :status, :result)

def init_server(server)
  @processes = {}
  @wait_queue = Thread::Queue.new

  # POST {LanguageId, sourceCode, input} -> {status, id}
  server.mount_proc("/submit") do |req, res|
    res.content_type = "application/json"

    unless req.request_method === "POST"
      res.body = error_json("method must be POST")
      next
    end

    data = JSON.parse(req.body)
    if (reason = validate_request(data))
      res.body = error_json(reason)
      next
    end

    id = generate_id

    @processes[id] = ProcessData[data, :waiting, nil]
    @wait_queue.enq id

    res.body = JSON.generate({
      status: "success",
      id: id,
    })
  end

  # GET {id} -> {status, id, process: {status, result?: {exitcode, stdout, stderr, memory, time}}}
  server.mount_proc("/status") do |req, res|
    res.content_type = "application/json"

    unless req.request_method === "GET"
      res.body = error_json("method must be GET")
      next
    end

    id = req.query["id"]

    unless @process.key? id
      res.body = error_json("id not found")
      next
    end

    process = @process[id]

    res.body = JSON.generate({
      status: "success",
      id: id,
      process: {
        status: process[:status],
        result: process[:result],
      },
    })
  end

  @pool = 5.times.map do
    Thread.fork do
      loop do
        id = @wait_queue.deq
        data = @processes[id]
        run_program(data)
      end
    end
  end
end

def run_program(data)
  data.status = :running

  tmpdir do
    lang = LANGS[data.request["lang"]]

    source_file = lang[0]
    File.open(source_file, "w") { |f| f << data.request["sourceCode"] }
    data.request["sourceCode"] = nil

    result = {
      exitcode: nil,
      stdout: nil,
      stderr: nil,
      memory: nil,
      time: nil,
    }
    data.result = result

    # compile
    IO.popen(lang[1], "r+", err: "compile_error.txt") do |io|
      stdput = io.read
      io.close
      exitcode = $?.exitcode
      unless exitcode == 0
        result.exitcode = exitcode
        data.status = :compile_error
      end
    end

    next if data.status == :compile_error

    # run

  end
end

def validate_request(data)
  unless data.key? "lang"
    return "lang not specified"
  end
  unless LANGS.key? data["lang"]
    return "lang not found"
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

def tmpdir
  pwd = Dir.pwd
  Dir.mktmpdir do |dir|
    Dir.chdir dir
    res = yield
    Dir.chdir pwd
    res
  end
end

main