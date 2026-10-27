# frozen_string_literal: true
# dn1sup_benchmark/test/png_gen_test.rb — генератор PNG-текстур.

require_relative 'test_helper'

module Dn1supBenchmark::Test
  test 'PNG генерируется: сигнатура и размер' do
    path = File.join(Dn1supBenchmark::PngGen.texture_dir, 'test_64.png')
    _path, bytes = Dn1supBenchmark::PngGen.write(path, 64)
    begin
      assert(File.exist?(path), 'файл не создан')
      assert(bytes > 100, "подозрительно маленький PNG: #{bytes} байт")
      head = File.binread(path, 8)
      assert_equal("\x89PNG\r\n\x1a\n".b, head, 'сигнатура PNG не совпала')
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  test 'кэш текстур отдаёт пути существующих файлов' do
    h = Dn1supBenchmark::PngGen.cached_textures([128])
    begin
      assert(h.key?('128'), "ожидали ключ '128', получили #{h.keys.inspect}")
      assert(File.exist?(h['128']), "нет файла #{h['128']}")
      assert(File.size(h['128']) > 100, 'кэшированный PNG пуст')
    ensure
      File.delete(h['128']) if h['128'] && File.exist?(h['128'])
    end
  end
end
