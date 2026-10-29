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

  test 'NoiseWriter: кусочная генерация байт-в-байт как write()' do
    dir = Dn1supBenchmark::PngGen.texture_dir
    a_path = File.join(dir, 'test_writer_a.png')
    b_path = File.join(dir, 'test_writer_b.png')
    begin
      Dn1supBenchmark::PngGen.write(a_path, 48)
      w = Dn1supBenchmark::PngGen::NoiseWriter.new(b_path, 48)
      refute(w.cached?, 'файла ещё нет — генерация с нуля')
      w.tick(0, 20)
      w.tick(20, 48)
      assert_equal(48, w.done, 'все строки посчитаны')
      bytes = w.finish!
      assert_equal(File.size(a_path), bytes, 'размер совпал с write()')
      assert_equal(File.binread(a_path), File.binread(b_path), 'PNG побайтово идентичен')
      # Повторное открытие — кэш: тики мгновенны, размер тот же.
      w2 = Dn1supBenchmark::PngGen::NoiseWriter.new(b_path, 48)
      assert(w2.cached?, 'готовый файл распознаётся как кэш')
      w2.tick(0, 48)
      assert_equal(bytes, w2.finish!, 'кэш возвращает размер без генерации')
    ensure
      [a_path, b_path].each { |p| File.delete(p) if File.exist?(p) }
    end
  end

  test 'NoiseWriter: разные соли дают разные файлы (анти-дедупликация)' do
    # SketchUp дедуплицирует одинаковые изображения в .skp — текстуры
    # тяжёлого файла обязаны различаться (инцидент калибровки 0.5.0).
    dir = Dn1supBenchmark::PngGen.texture_dir
    p1 = File.join(dir, 'test_salt_1.png')
    p2 = File.join(dir, 'test_salt_2.png')
    begin
      w1 = Dn1supBenchmark::PngGen::NoiseWriter.new(p1, 32, 1)
      w1.tick(0, 32)
      b1 = w1.finish!
      w2 = Dn1supBenchmark::PngGen::NoiseWriter.new(p2, 32, 2)
      w2.tick(0, 32)
      b2 = w2.finish!
      assert(b1.positive? && b2.positive?, 'файлы должны быть непустыми')
      assert(File.binread(p1) != File.binread(p2), 'соли должны давать разный контент')
    ensure
      [p1, p2].each { |p| File.delete(p) if File.exist?(p) }
    end
  end
end
