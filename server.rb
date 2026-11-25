# frozen_string_literal: true

# Local app for batch replacement of text and QR code in QuizPlease PSD mockups.
# Requires macOS + Adobe Photoshop 2023 (ExtendScript support).

require 'webrick'
require 'json'
require 'fileutils'
require 'securerandom'
require 'socket'
require 'time'

# Finder launches .app bundles without a UTF-8 locale.
Encoding.default_external = Encoding::UTF_8
$stdout.sync = true

ROOT = File.expand_path(__dir__)
STAGE_ROOT = '/private/tmp/quizplease-spb-jobs'
INPUT_ROOT = File.join(STAGE_ROOT, '_inputs')
JOBS_DIR = ENV['JOBS_DIR'] || File.join(ENV['HOME'], 'Library/Application Support/QuizPlease SPB/jobs')
DEFAULT_FOLDER = File.join(ENV['HOME'], 'Documents/QuizPlease SPB')
TEMPLATE = File.join(ROOT, 'render_template.jsx')
DIPLOMA_TEMPLATE = File.join(ROOT, 'render_diploma.jsx')
EMBEDDED_QR = File.join(ROOT, 'QR_SPB.png')
LOGO = File.join(ROOT, 'logo.png')
CHOOSER = ENV['CHOOSER'] || File.join(ROOT, 'choose_inputs.jxa')
INDEX = File.join(ROOT, 'index.html')

def find_free_port(start_port)
  (start_port..(start_port + 20)).each do |port|
    begin
      socket = TCPServer.new('127.0.0.1', port)
      socket.close
      return port
    rescue Errno::EADDRINUSE
      next
    end
  end
  start_port
end

def detect_photoshop
  return ENV['PS_APP'] unless ENV['PS_APP'].to_s.empty?

  apps = []
  ['/Applications', '/Applications/Utilities', File.join(ENV['HOME'], 'Applications')].each do |dir|
    next unless File.directory?(dir)
    apps.concat(Dir.glob(File.join(dir, 'Adobe Photoshop*.app')).map { |p| File.basename(p, '.app') })
  end
  apps.uniq!

  preferred = ['Adobe Photoshop 2026', 'Adobe Photoshop 2025', 'Adobe Photoshop 2024',
               'Adobe Photoshop 2023', 'Adobe Photoshop']
  preferred.each { |name| return name if apps.include?(name) }

  # Fall back to the newest version found (e.g. "Adobe Photoshop CC 2019").
  apps.max_by { |name| name[/20\d{2}/].to_i } || 'Adobe Photoshop 2023'
end

PS_APP = detect_photoshop
PORT = (ENV['PORT'] || find_free_port(4567)).to_i
JOB_TIMEOUT = (ENV['JOB_TIMEOUT'] || 600).to_i

OLD_TAG = '#квизплиз'
NEW_TAG = '#квизплизспб'
OLD_SITE = 'quizplease.ru'
NEW_SITE = 'spb.quizplease.ru'

FileUtils.mkdir_p(JOBS_DIR)
FileUtils.mkdir_p(INPUT_ROOT)
FileUtils.mkdir_p(DEFAULT_FOLDER)

class Job
  attr_accessor :id, :status, :message, :output, :log, :created_at, :dir, :stage_dir,
                :source_name, :folder, :final_path, :mode

  def initialize(id, source_name, folder, stage_dir, mode)
    @id = id
    @source_name = source_name
    @folder = folder
    @stage_dir = stage_dir
    @mode = mode
    @status = 'queued'
    @message = 'В очереди'
    @output = nil
    @final_path = nil
    @log = []
    @created_at = Time.now
    @dir = File.join(JOBS_DIR, id)
  end

  def to_h
    {
      id: id,
      name: source_name,
      mode: mode,
      status: status,
      message: message,
      final_path: final_path,
      folder: folder,
      output: output ? "/api/jobs/#{id}/download" : nil,
      log: log.last(30),
      created_at: created_at.iso8601
    }
  end
end

$mutex = Mutex.new
$queue = []
$jobs = {}
$inputs = {}
$cv = ConditionVariable.new

def js_string(str)
  out = +''
  str.each_char do |ch|
    case ch
    when '\\' then out << '\\\\'
    when "'" then out << "\\'"
    when "\n" then out << '\\n'
    when "\r" then out << '\\r'
    when "\t" then out << '\\t'
    else
      cp = ch.ord
      if cp < 32 || cp > 126
        out << format('\\u%04x', cp)
      else
        out << ch
      end
    end
  end
  out
end

def render_jsx(job, psd_path, qr_path)
  result_path = File.join(job.stage_dir, 'result.txt')
  log_path = File.join(job.stage_dir, 'log.txt')
  out_path = File.join(job.stage_dir, 'out.tif')
  template = job.mode == 'diploma' ? DIPLOMA_TEMPLATE : TEMPLATE
  tpl = File.read(template, encoding: 'UTF-8')
  replacements = {
    '__PSD_PATH__' => js_string(psd_path),
    '__QR_PATH__' => js_string(qr_path),
    '__OUT_PATH__' => js_string(out_path),
    '__RESULT_PATH__' => js_string(result_path),
    '__LOG_PATH__' => js_string(log_path),
    '__STAGE_ROOT__' => js_string(STAGE_ROOT),
    '__OLD_TAG__' => js_string(OLD_TAG),
    '__NEW_TAG__' => js_string(NEW_TAG),
    '__OLD_SITE__' => js_string(OLD_SITE),
    '__NEW_SITE__' => js_string(NEW_SITE)
  }
  replacements.each do |key, value|
    tpl.gsub!(key) { value }
  end
  jsx_path = File.join(job.dir, 'render.jsx')
  File.write(jsx_path, tpl, encoding: 'UTF-8')
  [jsx_path, result_path, out_path]
end

def parse_result(path)
  content = File.read(path, encoding: 'UTF-8')
  return nil unless content.include?('STATUS=') && content.include?('MESSAGE=')

  result = { status: 'ERROR', message: 'Результат не получен', log: [] }
  content.gsub("\r\n", "\n").gsub("\r", "\n").each_line do |line|
    # ExtendScript sometimes writes Cyrillic with stray en-dashes in UTF-8.
    line = line.chomp.gsub("\u2013", '')
    case line
    when /\ASTATUS=(.*)\z/ then result[:status] = Regexp.last_match(1)
    when /\AMESSAGE=(.*)\z/ then result[:message] = Regexp.last_match(1)
    when /\ALOG=(.*)\z/ then result[:log] << Regexp.last_match(1)
    end
  end
  result
end

def unique_path(folder, base_name)
  path = File.join(folder, base_name)
  return path unless File.exist?(path)

  ext = File.extname(base_name)
  stem = File.basename(base_name, ext)
  n = 2
  loop do
    candidate = File.join(folder, "#{stem} (#{n})#{ext}")
    return candidate unless File.exist?(candidate)
    n += 1
  end
end

def run_job(job)
  job.status = 'running'
  job.message = 'Photoshop обрабатывает макет…'
  job.log << 'Запуск Photoshop'

  psd_path = File.join(job.stage_dir, 'input.psd')
  qr_path = File.join(job.stage_dir, 'qr.png')
  jsx_path, result_path, out_path = render_jsx(job, psd_path, qr_path)
  File.delete(result_path) if File.exist?(result_path)
  File.delete(out_path) if File.exist?(out_path)
  final_out = File.join(job.dir, 'out.tif')

  # -j launches Photoshop without stealing focus; no Apple Events are sent.
  ok = system('open', '-j', '-a', PS_APP, jsx_path)
  unless ok
    job.status = 'error'
    job.message = "Не удалось запустить Photoshop (#{PS_APP})"
    return
  end

  deadline = Time.now + JOB_TIMEOUT
  result = nil
  while Time.now < deadline
    if File.exist?(result_path)
      size1 = File.size(result_path)
      mtime1 = File.mtime(result_path)
      sleep 1
      if File.exist?(result_path) && File.size(result_path) == size1 && File.mtime(result_path) == mtime1
        begin
          result = parse_result(result_path)
          break if result
        rescue StandardError
          # file may still be partially written
        end
      end
    end
    sleep 1
  end

  if result.nil?
    job.status = 'error'
    job.message = 'Превышено время ожидания Photoshop. Проверьте, нет ли диалога в Photoshop.'
    job.log << 'Timeout'
    return
  end

  job.log.concat(result[:log])
  if result[:status] == 'OK' && File.exist?(out_path) && File.size(out_path) > 0
    FileUtils.cp(out_path, final_out)
    FileUtils.mkdir_p(job.folder)
    base = File.basename(job.source_name, File.extname(job.source_name)) + '_spb.tif'
    dest = unique_path(job.folder, base)
    FileUtils.cp(out_path, dest)
    job.final_path = dest
    job.output = final_out
    job.status = 'done'
    job.message = 'Готово'
  else
    job.status = 'error'
    job.message = result[:message].to_s.empty? ? 'Ошибка рендера' : result[:message]
  end
rescue StandardError => e
  job.status = 'error'
  job.message = "#{e.class}: #{e.message}"
  job.log << e.backtrace.first.to_s
end

def queue_worker
  loop do
    job = nil
    $mutex.synchronize do
      $cv.wait($mutex) if $queue.empty?
      job = $queue.shift
    end
    next unless job

    run_job(job)
  end
end

Thread.new { queue_worker }

def json_response(res, obj, code = 200)
  res.status = code
  res['Content-Type'] = 'application/json; charset=utf-8'
  res.body = JSON.generate(obj)
end

def inputs_list
  $mutex.synchronize do
    $inputs.values.sort_by { |i| i[:name].downcase }.map do |i|
      { id: i[:id], name: i[:name], size: i[:size], source: i[:source], mode: i[:mode] || 'blank' }
    end
  end
end

def add_input_file(path, errors, display_name: nil, origin: nil, staged: nil, mode: 'blank')
  path = path.to_s.dup.force_encoding(Encoding::UTF_8)
  name = (display_name || File.basename(path)).to_s.dup.force_encoding(Encoding::UTF_8)
  unless name.downcase.end_with?('.psd')
    errors << "#{name}: нужен файл .psd"
    return
  end

  size = File.size(path)
  if size > 300 * 1024 * 1024
    errors << "#{name}: файл слишком большой (лимит 300 МБ)"
    return
  end

  origin ||= path
  existing = $mutex.synchronize { $inputs.values.find { |i| i[:origin] == origin && i[:mode] == mode } }
  return if existing

  id = SecureRandom.hex(6)
  staged ||= File.join(INPUT_ROOT, "#{id}.psd")
  FileUtils.cp(path, staged) unless staged == path
  $mutex.synchronize do
    $inputs[id] = { id: id, name: name, size: size, path: staged, source: origin, origin: origin, mode: mode }
  end
end

def add_input_path(path, errors, mode = 'blank')
  path = path.to_s.dup.force_encoding(Encoding::UTF_8)
  unless File.exist?(path)
    errors << "Не найдено: #{path}"
    return
  end

  if File.directory?(path)
    folder_name = File.basename(path)
    prefix = path.end_with?('/') ? path : path + '/'
    files = Dir.glob(File.join(path, '**', '*')).select do |f|
      File.file?(f) && File.extname(f).downcase == '.psd'
    end.sort_by { |f| f.downcase }
    errors << "В папке «#{folder_name}» нет PSD-файлов" if files.empty?
    files.each do |f|
      relative = f.start_with?(prefix) ? f.delete_prefix(prefix) : File.basename(f)
      add_input_file(f, errors, display_name: File.join(folder_name, relative), origin: f, mode: mode)
    end
  else
    add_input_file(path, errors, mode: mode)
  end
end

def save_upload(part, path)
  return false unless part.respond_to?(:to_str)

  File.binwrite(path, part.b)
  true
end

def upload_parts(query)
  keys = query.keys.select { |k| k.to_s =~ /\Apsd(?:_\d+)?\z/ }
  keys.sort_by! { |k| k.to_s[/\d+/].to_i }
  keys.map { |k| query[k] }.select do |p|
    p.is_a?(WEBrick::HTTPUtils::FormData) && p.filename && p.size.to_i > 0
  end
end

def save_uploaded_parts(query, mode = 'blank')
  errors = []
  upload_parts(query).each_with_index do |part, i|
    name = query["name_#{i}"].to_s.dup.force_encoding(Encoding::UTF_8)
    name = File.basename(part.filename.to_s.dup.force_encoding(Encoding::UTF_8)) if name.empty?
    unless name.downcase.end_with?('.psd')
      errors << "#{name}: нужен файл .psd"
      next
    end
    if part.size.to_i > 300 * 1024 * 1024
      errors << "#{name}: файл слишком большой (лимит 300 МБ)"
      next
    end
    origin = "upload:#{name}:#{part.size}:#{mode}"
    existing = $mutex.synchronize { $inputs.values.find { |x| x[:origin] == origin } }
    next if existing

    id = SecureRandom.hex(6)
    staged = File.join(INPUT_ROOT, "#{id}.psd")
    save_upload(part, staged)
    $mutex.synchronize do
      $inputs[id] = { id: id, name: name, size: part.size.to_i, path: staged,
                      source: name, origin: origin, mode: mode }
    end
  end
  errors
end

def remove_input(id)
  staged = $mutex.synchronize do
    item = $inputs.delete(id)
    item && item[:path]
  end
  FileUtils.rm_f(staged) if staged
end

def clear_inputs
  staged = $mutex.synchronize do
    paths = $inputs.values.map { |i| i[:path] }
    $inputs.clear
    paths
  end
  staged.each { |p| FileUtils.rm_f(p) }
end

def apple_script(script)
  out = IO.popen(['osascript', '-e', script], err: [:child, :out], &:read).to_s.strip
  out.force_encoding(Encoding::UTF_8)
  out
end

server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: '127.0.0.1',
  Logger: WEBrick::Log.new(File::NULL),
  AccessLog: []
)

server.mount_proc '/' do |req, res|
  path = req.path

  if path == '/' || path == '/index.html'
    res['Content-Type'] = 'text/html; charset=utf-8'
    res.body = File.read(INDEX, encoding: 'UTF-8')
  elsif path == '/logo.png' && req.request_method == 'GET'
    res['Content-Type'] = 'image/png'
    res.body = File.binread(LOGO)
  elsif path == '/api/config' && req.request_method == 'GET'
    json_response(res, { folder: DEFAULT_FOLDER, ps_app: PS_APP, port: PORT })
  elsif path == '/api/choose-folder' && req.request_method == 'POST'
    begin
      chosen = apple_script('return POSIX path of (choose folder with prompt "Выберите папку для готовых TIFF")')
      json_response(res, chosen.empty? ? { cancel: true } : { path: chosen })
    rescue StandardError => e
      json_response(res, { cancel: true, message: e.message })
    end
  elsif path == '/api/open-folder' && req.request_method == 'POST'
    begin
      folder = req.query['path'].to_s.dup.force_encoding(Encoding::UTF_8)
      folder = DEFAULT_FOLDER if folder.empty?
      FileUtils.mkdir_p(folder)
      system('open', folder)
      json_response(res, { ok: true })
    rescue StandardError => e
      json_response(res, { error: e.message }, 500)
    end
  elsif path == '/api/choose-inputs' && req.request_method == 'POST'
    begin
      # WEBrick does not merge a URL query string into req.query for POST here.
      raw_mode = WEBrick::HTTPUtils.parse_query(req.request_uri.query.to_s)['mode'].to_s
      raw_mode = req.query['mode'].to_s if raw_mode.empty?
      mode = raw_mode == 'diploma' ? 'diploma' : 'blank'
      title = mode == 'diploma' ? 'Выберите дипломы или папки с дипломами' : 'Выберите бланки или папки с бланками'
      # JXA console.log writes to stderr, so capture both streams and mark real
      # paths with a PATH: prefix to tell them apart from osascript diagnostics.
      out = IO.popen({ 'QP_PICKER_TITLE' => title }, ['osascript', '-l', 'JavaScript', CHOOSER],
                     err: [:child, :out], &:read).to_s
      out.force_encoding(Encoding::UTF_8)
      lines = out.lines.map { |l| l.strip }.reject(&:empty?)
      paths = lines.select { |l| l.start_with?('PATH:') }.map { |l| l.delete_prefix('PATH:') }
      err_lines = lines.reject { |l| l.start_with?('PATH:') }
      errors = []
      unless err_lines.empty?
        $stderr.puts "CHOOSER_ERROR: #{err_lines.join(' | ')}"
        errors << "Диалог выбора: #{err_lines.first}" if paths.empty?
      end
      paths.each { |p| add_input_path(p, errors, mode) }
      json_response(res, { inputs: inputs_list, errors: errors, cancelled: paths.empty? && errors.empty? })
    rescue StandardError => e
      json_response(res, { error: "#{e.class}: #{e.message}" }, 500)
    end
  elsif path == '/api/inputs' && req.request_method == 'GET'
    json_response(res, { inputs: inputs_list })
  elsif path == '/api/inputs' && req.request_method == 'POST'
    begin
      mode = req.query['mode'].to_s == 'diploma' ? 'diploma' : 'blank'
      errors = save_uploaded_parts(req.query, mode)
      json_response(res, { inputs: inputs_list, errors: errors })
    rescue StandardError => e
      json_response(res, { error: "#{e.class}: #{e.message}" }, 500)
    end
  elsif (m = path.match(%r{\A/api/inputs/([^/]+)\z})) && req.request_method == 'DELETE'
    remove_input(m[1])
    json_response(res, { ok: true, inputs: inputs_list })
  elsif path == '/api/inputs' && req.request_method == 'DELETE'
    clear_inputs
    json_response(res, { ok: true, inputs: [] })
  elsif path == '/api/inputs/remove' && req.request_method == 'POST'
    id = begin
      JSON.parse(req.body.to_s)['id'].to_s
    rescue StandardError
      req.query['id'].to_s
    end
    remove_input(id)
    json_response(res, { ok: true, inputs: inputs_list })
  elsif path == '/api/inputs/clear' && req.request_method == 'POST'
    clear_inputs
    json_response(res, { ok: true, inputs: [] })
  elsif path == '/api/jobs' && req.request_method == 'POST'
    begin
      content_type = req['content-type'].to_s
      body_folder = nil
      if content_type.include?('json')
        begin
          body_folder = JSON.parse(req.body.to_s)['folder'].to_s
        rescue StandardError
          body_folder = nil
        end
        upload_errors = []
      else
        upload_mode = req.query['mode'].to_s == 'diploma' ? 'diploma' : 'blank'
        upload_errors = save_uploaded_parts(req.query, upload_mode)
        body_folder = req.query['folder'].to_s
      end

      picked = $mutex.synchronize do
        list = $inputs.values
        $inputs.clear
        list
      end
      if picked.empty?
        json_response(res, { error: 'Сначала добавьте макеты или папку', errors: upload_errors }, 400)
        next
      end

      folder = body_folder.to_s.dup.force_encoding(Encoding::UTF_8).strip
      folder = DEFAULT_FOLDER if folder.empty?

      created = []
      errors = upload_errors
      picked.each do |input|
        begin
          id = Time.now.strftime('%Y%m%d-%H%M%S') + '-' + SecureRandom.hex(4)
          dir = File.join(JOBS_DIR, id)
          stage_dir = File.join(STAGE_ROOT, id)
          FileUtils.mkdir_p(dir)
          FileUtils.mkdir_p(stage_dir)
          FileUtils.cp(input[:path], File.join(stage_dir, 'input.psd'))
          FileUtils.cp(EMBEDDED_QR, File.join(stage_dir, 'qr.png'))
          FileUtils.mkdir_p(folder)

          job = Job.new(id, input[:name], folder, stage_dir, input[:mode] || 'blank')
          $mutex.synchronize do
            $jobs[id] = job
            $queue << job
            $cv.signal
          end
          created << job.to_h
        rescue StandardError => e
          errors << "#{input[:name]}: #{e.message}"
        ensure
          FileUtils.rm_f(input[:path])
        end
      end

      json_response(res, { jobs: created, errors: errors, folder: folder })
    rescue StandardError => e
      json_response(res, { error: "#{e.class}: #{e.message}" }, 500)
    end
  elsif (m = path.match(%r{\A/api/jobs/([^/]+)\z})) && req.request_method == 'GET'
    job = $mutex.synchronize { $jobs[m[1]] }
    if job
      json_response(res, job.to_h)
    else
      json_response(res, { error: 'Job not found' }, 404)
    end
  elsif (m = path.match(%r{\A/api/jobs/([^/]+)/download\z})) && req.request_method == 'GET'
    job = $mutex.synchronize { $jobs[m[1]] }
    if job && job.output && File.exist?(job.output)
      res['Content-Type'] = 'image/tiff'
      res['Content-Disposition'] = 'attachment; filename="quizplease-spb.tif"'
      res.body = File.binread(job.output)
    else
      json_response(res, { error: 'File not ready' }, 404)
    end
  elsif path == '/api/photoshop/restart' && req.request_method == 'POST'
    system('killall', PS_APP)
    sleep 2
    system('open', '-j', '-a', PS_APP)
    json_response(res, { ok: true })
  else
    res.status = 404
    res.body = 'Not found'
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

puts "PORT=#{PORT}"
puts "QuizPlease SPB app: http://127.0.0.1:#{PORT}"
server.start
