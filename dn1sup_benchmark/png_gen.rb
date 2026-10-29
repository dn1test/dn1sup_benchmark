# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/png_gen.rb — генератор PNG-текстур чистым Ruby (stdlib zlib).
#
# Текстуры нужны тесту файла ~500 МБ (большие шумовые PNG встраиваются в
# .skp материалами); чтобы не таскать бинарные ассеты в .rbz, PNG собирается
# на месте. Пиксели детерминированные (только формулы от x/y) — одна и та
# же текстура на любой машине и версии SketchUp, поэтому файлы кэшируются
# во временной папке и переиспользуются между прогонами.
#
# Два способа сборки:
#   • write(path, size) — синхронно, целиком (мелкие текстуры, тесты);
#   • NoiseWriter — КУСОЧНО: строки добавляются порциями ~1 с (UI-поток
#     свободен, работает отмена), сжатие feeding инкрементально; пиксельный
#     профиль идентичен write() — файлы побайтово совпадают.
# =============================================================================

require 'zlib'
require 'tmpdir'

module Dn1supBenchmark
  module PngGen
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

    class << self
      # Пишет RGB-PNG size×size с псевдошумом. Возвращает [путь, байт].
      def write(path, size)
        w = NoiseWriter.new(path, size)
        w.tick(0, size)
        _bytes = w.finish!
        [path, File.size(path)]
      end

      def chunk(type, data)
        [data.bytesize].pack('N') + type.b + data + [Zlib::crc32(type.b + data)].pack('N')
      end

      # Корневая временная папка бенчмарка (текстуры, файлы storage и пр.).
      def temp_root
        base = ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir
        mkdir_p(File.join(base, 'dn1sup_benchmark'))
      end

      # Каталог кэша текстур бенчмарка (создаётся по требованию).
      def texture_dir
        dir = File.join(temp_root, 'textures')
        mkdir_p(dir)
        dir
      end

      # Возвращает путь к кэшированной текстуре заданного размера (генерирует
      # при первом обращении). [{ '256' => путь, ... }]
      def cached_textures(sizes)
        dir = texture_dir
        sizes.each_with_object({}) do |s, h|
          path = File.join(dir, "noise_#{s}.png")
          write(path, s) unless File.exist?(path) && File.size(path) > 8
          h[s.to_s] = path
        end
      end

      # mkdir -p без fileutils: каталоги могут быть вложенными.
      def mkdir_p(dir)
        parts = File.expand_path(dir).split(File::SEPARATOR)
        cur = parts.shift + File::SEPARATOR
        parts.each do |p|
          cur = File.join(cur, p)
          Dir.mkdir(cur) unless Dir.exist?(cur)
        end
        dir
      end
    end

    # Кусочный генератор шумового PNG: tick(from, to) добавляет строки
    # [from, to), finish! дописывает файл и возвращает размер в байтах.
    # Если путь уже закэширован — все тики мгновенны (cached?).
    # salt замешивается в пиксели: текстуры с разной солью дают РАЗНЫЕ
    # файлы (SketchUp дедуплицирует одинаковые изображения при вставке
    # в .skp — одинаковый шум съедал бы размер тяжёлого файла).
    class NoiseWriter
      def initialize(path, size, salt = 0)
        @path = path.to_s
        @size = size.to_i
        @salt = salt.to_i
        if File.exist?(@path) && File.size(@path) > 8
          @cached = true
          @done = @size
          @bytes = File.size(@path)
        else
          @cached = false
          @done = 0
          @deflater = Zlib::Deflate.new(1)
          ihdr = [@size, @size].pack('NN') + "\x08\x02\x00\x00\x00".b # depth 8, RGB
          @head = PNG_SIGNATURE.dup << PngGen.chunk('IHDR', ihdr)
        end
      end

      def cached?
        @cached
      end

      # Сколько строк уже сгенерировано (для планирования порций).
      def done
        @done
      end

      def tick(from, to)
        return if @cached

        from.upto(to - 1) do |y|
          @deflater << row(y)
          @done += 1
        end
      end

      def finish!
        return @bytes if @cached

        raise 'не все строки сгенерированы' if @done < @size

        png = @head << PngGen.chunk('IDAT', @deflater.finish) << PngGen.chunk('IEND', ''.b)
        File.binwrite(@path, png)
        @bytes = png.bytesize
      end

      private

      # Одна scanline: фильтр 0 (None) + size пикселей того же профиля,
      # что и в оригинальном генераторе (при salt=0 — байт-в-байт как
      # PngGen.write); соль сдвигает каналы, делая файлы уникальными.
      def row(y)
        line = "\x00".b.dup
        size = @size
        salt = @salt
        size.times do |x|
          r = (x * 3 + y * 7 + ((x * y) % 61) + salt * 17) & 0xFF
          g = (x * 5 + y * 11 + ((x + y + salt) % 43) + salt * 29) & 0xFF
          b = (x * 13 + y * 3 + ((x ^ y) % 31) + salt * 7) & 0xFF
          line << r.chr << g.chr << b.chr
        end
        line
      end
    end
  end
end
