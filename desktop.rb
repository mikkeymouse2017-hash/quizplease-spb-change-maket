# frozen_string_literal: true

# Standalone desktop mode for QuizPlease SPB.
# Can be run directly (CLI with --psd) or packaged into a .app (see build_app.sh).
# Uses only Ruby stdlib + osascript native dialogs + Photoshop .jsx automation.

require 'fileutils'
require 'securerandom'
require 'time'

# Finder launches .app bundles without a UTF-8 locale. Ruby then treats
# osascript output (Russian paths) as US-ASCII and fails with
# "invalid byte sequence in US-ASCII".
Encoding.default_external = Encoding::UTF_8

ROOT = File.expand_path(__dir__)
TEMPLATE = File.join(ROOT, 'render_template.jsx')
EMBEDDED_QR = File.join(ROOT, 'QR_SPB.png')
STAGE_ROOT = '/private/tmp/quizplease-spb-jobs'
PS_APP = ENV['PS_APP'] || 'Adobe Photoshop 2023'
JOB_TIMEOUT = (ENV['JOB_TIMEOUT'] || 600).to_i
LOG_FILE = File.join(ENV['HOME'], 'Library/Logs/QuizPleaseSPB.log')

def log(line)
  FileUtils.mkdir_p(File.dirname(LOG_FILE))
  File.open(LOG_FILE, 'a') { |f| f.puts "[#{Time.now}] #{line}" }
  puts line
end

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
      cp < 32 || cp > 126 ? out << format('\\u%04x', cp) : out << ch
    end
  end
  out
end

def apple_script(script)
  out = IO.popen(['osascript', '-e', script], err: [:child, :out], &:read).to_s.strip
  out.force_encoding(Encoding::UTF_8)
  out
end

def notify(text)
  safe = text.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
  apple_script("display notification \"#{safe}\" with title \"QuizPlease SPB\"")
rescue StandardError
  nil
end

def dialog(text, buttons = ['OK'])
  safe = text.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("\n", '\\n')
  btn = buttons.map { |b| "\"#{b}\"" }.join(', ')
  apple_script("display dialog \"#{safe}\" buttons {#{btn}} default button \"#{buttons.first}\" with title \"QuizPlease SPB\"")
end

def hfs_to_posix(path)
  return path unless path.start_with?('file ') && path.include?(':')

  hfs = path.sub(/\Afile /, '')
  escaped = hfs.gsub('\\', '\\\\').gsub('"', '\\"')
  converted = apple_script("return POSIX path of (\"#{escaped}\" as alias)")
  converted.empty? ? path : converted
end

def choose_psd
  script = <<~APPLESCRIPT
    try
      set f to choose file of type {"psd"} with prompt "Выберите PSD-макет"
      return POSIX path of f
    on error
      return ""
    end try
  APPLESCRIPT
  path = hfs_to_posix(apple_script(script))
  return nil if path.empty?

  path
end

def parse_result(path)
  content = File.read(path, encoding: 'UTF-8')
  return nil unless content.include?('STATUS=') && content.include?('MESSAGE=')

  result = { status: 'ERROR', message: '', log: [] }
  content.gsub("\r\n", "\n").gsub("\r", "\n").each_line do |line|
    case line.chomp
    when /\ASTATUS=(.*)\z/ then result[:status] = Regexp.last_match(1)
    when /\AMESSAGE=(.*)\z/ then result[:message] = Regexp.last_match(1)
    when /\ALOG=(.*)\z/ then result[:log] << Regexp.last_match(1)
    end
  end
  result
end

def render_jsx(stage, psd_path, out_path, result_path, log_path)
  tpl = File.read(TEMPLATE, encoding: 'UTF-8')
  values = {
    '__PSD_PATH__' => js_string(psd_path),
    '__QR_PATH__' => js_string(File.join(stage, 'qr.png')),
    '__OUT_PATH__' => js_string(out_path),
    '__RESULT_PATH__' => js_string(result_path),
    '__LOG_PATH__' => js_string(log_path),
    '__STAGE_ROOT__' => js_string(STAGE_ROOT),
    '__OLD_TAG__' => js_string('#квизплиз'),
    '__NEW_TAG__' => js_string('#квизплизспб'),
    '__OLD_SITE__' => js_string('quizplease.ru'),
    '__NEW_SITE__' => js_string('spb.quizplease.ru')
  }
  values.each { |k, v| tpl.gsub!(k) { v } }
  path = File.join(stage, 'render.jsx')
  File.write(path, tpl, encoding: 'UTF-8')
  path
end

def convert(psd_path, out_path)
  raise "Файл не найден: #{psd_path}" unless File.exist?(psd_path)
  raise "Встроенный QR не найден: #{EMBEDDED_QR}" unless File.exist?(EMBEDDED_QR)

  id = Time.now.strftime('%Y%m%d-%H%M%S') + '-' + SecureRandom.hex(3)
  stage = File.join(STAGE_ROOT, id)
  FileUtils.mkdir_p(stage)

  staged_psd = File.join(stage, 'input.psd')
  FileUtils.cp(psd_path, staged_psd)
  FileUtils.cp(EMBEDDED_QR, File.join(stage, 'qr.png'))

  result_path = File.join(stage, 'result.txt')
  log_path = File.join(stage, 'log.txt')
  stage_out = File.join(stage, 'out.tif')
  jsx = render_jsx(stage, staged_psd, stage_out, result_path, log_path)

  log('Запуск Photoshop…')
  notify('Photoshop обрабатывает макет…')
  unless system('open', '-j', '-a', PS_APP, jsx)
    raise 'Не удалось запустить Photoshop'
  end

  deadline = Time.now + JOB_TIMEOUT
  result = nil
  while Time.now < deadline
    if File.exist?(result_path)
      size1 = File.size(result_path)
      mt1 = File.mtime(result_path)
      sleep 1
      if File.exist?(result_path) && File.size(result_path) == size1 && File.mtime(result_path) == mt1
        begin
          result = parse_result(result_path)
          break if result
        rescue StandardError
          # still writing
        end
      end
    end
    sleep 1
  end
  raise 'Превышено время ожидания Photoshop' unless result

  result[:log].each { |l| log(l) }
  unless result[:status] == 'OK' && File.exist?(stage_out) && File.size(stage_out) > 0
    raise result[:message].to_s.empty? ? 'Ошибка рендера' : result[:message]
  end

  FileUtils.mkdir_p(File.dirname(out_path))
  FileUtils.cp(stage_out, out_path)
  out_path
end

# --- entry point ---

args = ARGV.dup
no_gui = args.delete('--no-gui')
psd_path = nil
out_path = nil
if (i = args.index('--psd'))
  psd_path = args[i + 1]
end
if (i = args.index('--out'))
  out_path = args[i + 1]
end

begin
  unless psd_path
    psd_path = choose_psd
    if psd_path.nil? || psd_path.empty?
      log('Отменено')
      exit 0
    end
  end

  out_path ||= psd_path.sub(/\.psd$/i, '_spb.tif')
  result = convert(psd_path, out_path)
  notify('Готово — TIFF сохранён')
  unless no_gui
    response = dialog("Готово!\n\nTIFF сохранён:\n#{result}", ['Показать в Finder', 'OK'])
    system('open', '-R', result) if response.include?('Показать в Finder')
  end
rescue StandardError => e
  msg = "#{e.message}"
  log("ERROR: #{msg}")
  notify("Ошибка: #{msg}")
  dialog("Не удалось создать TIFF:\n\n#{msg}") unless no_gui
  exit 1
end
