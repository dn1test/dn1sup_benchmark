# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/png_gen.rb — генератор PNG-текстур чистым Ruby (stdlib zlib).
#
# Текстуры нужны бенчмарку для тестов наложения/загрузки; чтобы не таскать
# бинарные ассеты в .rbz, PNG собирается на месте: сигнатура + IHDR + IDAT
# (zlib, уровень 1 — генерация не должна доминировать над загрузкой) + IEND.
# Пиксели детерминированные (только формулы от x/y) — одна и та же текстура
# на любой машине и версии SketchUp.
# =============================================================================

require 'zlib'

module Dn1supBenchmark
  module PngGen
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

    # Пишет RGB-PNG size×size с псевдошумом. Возвращает [путь, байт].
    def self.write(path, size)
      raw = +''.b
      size.times do |y|
        raw << "\x00".b # filter type 0 (None) для каждой scanline
        size.times do |x|
          r = (x * 3 + y * 7 + ((x * y) % 61)) & 0xFF
          g = (x * 5 + y * 11 + ((x + y) % 43)) & 0xFF
          b = (x * 13 + y * 3 + ((x ^ y) % 31)) & 0xFF
          raw << r.chr << g.chr << b.chr
        end
      end

      ihdr = [size, size].pack('NN') + "\x08\x02\x00\x00\x00".b # depth 8, RGB
      idat = Zlib::Deflate.deflate(raw, 1)

      png = PNG_SIGNATURE.dup
      png << chunk('IHDR', ihdr)
      png << chunk('IDAT', idat)
      png << chunk('IEND', ''.b)

      File.binwrite(path, png)
      [path, png.bytesize]
    end

    def self.chunk(type, data)
      [data.bytesize].pack('N') + type.b + data + [Zlib.crc32(type.b + data)].pack('N')
    end

    # Каталог кэша текстур бенчмарка (создаётся по требованию).
    def self.texture_dir
      base = ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir
      dir = File.join(base, 'dn1sup_benchmark', 'textures')
      mkdir_p(dir)
      dir
    end

    # Возвращает путь к кэшированной текстуре заданного размера (генерирует
    # при первом обращении). [{ '256' => путь, ... }]
    def self.cached_textures(sizes)
      dir = texture_dir
      sizes.each_with_object({}) do |s, h|
        path = File.join(dir, "noise_#{s}.png")
        write(path, s) unless File.exist?(path) && File.size(path) > 8
        h[s.to_s] = path
      end
    end

    # mkdir -p без fileutils: каталоги могут быть вложенными.
    def self.mkdir_p(dir)
      parts = File.expand_path(dir).split(File::SEPARATOR)
      cur = parts.shift + File::SEPARATOR
      parts.each do |p|
        cur = File.join(cur, p)
        Dir.mkdir(cur) unless Dir.exist?(cur)
      end
      dir
    end
  end
end
