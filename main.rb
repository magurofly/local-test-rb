#!/usr/bin/env ruby
# coding: UTF-8

require "thread"
require "securerandom"
require "json"
require "webrick"
require "tmpdir"

def main
  @lang = JSON.parse(File.read("www/lang.json"))

  @process = {}
  @wait_queue = Thread::Queue.new

  @pool = 5.times.map do
    Thread.fork do
      loop do
        id = @wait_queue.deq
        data = @process[id]
        run_program(data)
        sleep 5
        @process.delete id
      end
    end
  end

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

ProcessData = Struct.new(:id, :request, :status, :result)
RequestData = Struct.new(:LanguageId, :sourceCode, :input)

def init_server(server)

  # POST {LanguageId, sourceCode, input} -> {status, result}
  server.mount_proc("/submit") do |req, res|
    res.content_type = "application/json"

    unless req.request_method === "POST"
      res.body = error_json("method must be POST")
      next
    end

    begin
      data = parse_request(JSON.parse(req.body))
    rescue => reason
      res.body = error_json(reason)
      next
    end

    id = generate_id

    puts "accepted #{id}"

    @process[id] = ProcessData[id, data, :waiting, nil]
    @wait_queue.enq id

    res.body = JSON.generate({
      status: "success",
      result: id,
    })
  end

  # GET {id} -> {status, result: {status, result?: {exitcode, stdout, stderr, memory, time}}}
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
      result: {
        status: process[:status],
        result: process[:result],
      },
    })
  end

  server.mount("/", WEBrick::HTTPServlet::FileHandler, "./www")
end

def run_program(data)
  data.status = :running
  id = data.id

  Dir.mktmpdir do |dir|
    lang = @lang[data.request.LanguageId]
    files = lang["files"].map { |filename| File.join(dir, filename) }
    compile_error = File.join(dir, "compile_error.txt")
    runtime_error = File.join(dir, "runtime_error.txt")
    time_file = File.join(dir, "time.txt")

    File.open(files[0], "w") { |f| f << data.request.sourceCode }
    data.request.sourceCode = nil

    result = {
      exitcode: nil,
      stdout: nil,
      stderr: nil,
      memory: nil,
      time: nil,
    }
    data.result = result

    # compile
    if lang["compile"]
      compile_command = lang["compile"].gsub(/\$\d+/) { |m| files[m[1..-1].to_i] }
      puts "compile #{id}"
      IO.popen(compile_command, "r+", err: compile_error) do |io|
        stdput = io.read
        io.close
        unless $?.exitstatus == 0
          result[:exitcode] = $?.exitstatus
          result[:stderr] = File.read(compile_error)
          data.status = :compile_error
        end
      end
    end

    if data.status == :compile_error
      puts "compile_error #{id}"
      next
    end

    # run
    run_command = lang["run"].gsub(/\$\d+/) { |m| files[m[1..-1].to_i] }
    puts "run #{id}: $ #{run_command}"
    IO.popen("timeout -s KILL 10 time -f '%e %M' -o '#{time_file}' #{run_command}", "r+", err: runtime_error) do |io|
      io << data.request.input
      result[:stdout] = io.read
      io.close
      result[:exitcode] = $?.exitstatus
      data.status = :compile_error unless $?.exitstatus == 0
    end

    result[:stderr] = File.read(runtime_error)
    time, memory = File.read(time_file).split.map &:to_f
    result[:time] = time * 1e3
    result[:memory] = memory

    puts "finish #{id}"

    data.status = :finished unless data.status == :runtime_error
  end
end

def parse_request(data)
  raise "LanguageId not specified" unless data.key? "LanguageId"
  raise "LanguageId not found" unless @lang.key? data["LanguageId"]

  raise "sourceCode not specified" unless data.key? "sourceCode"

  raise "input not specified" unless data.key? "input"

  RequestData[data["LanguageId"], data["sourceCode"], data["input"]]
end

def generate_id
  id = nil
  begin
    id = SecureRandom.uuid
  end while @process.key? id
  id
end

def error_json(reason)
  JSON.generate({
    status: "error",
    result: reason,
  })
end

main