# frozen_string_literal: true
# =============================================================================
# tools/gen_icon.rb — растеризация icons/bench.svg в bench_16.png / bench_24.png
# для UI::Command (small_icon/large_icon). Запуск из корня репозитория:
#   ruby tools/gen_icon.rb
#
# Источник правды — bench.svg; геометрия ниже повторяет его 1:1 (купол
# полукруга, игла-капсула, ступица, планка-подставка), поэтому при правке
# SVG синхронно правятся константы здесь. Рендер — сглаживание 4×4 на пиксель.
# =============================================================================

require 'zlib'

ICON_DIR = File.expand_path('../dn1sup_benchmark/icons', __dir__)
AMBER = [245, 158, 11]   # #f59e0b
WHITE = [255, 255, 255]

# Геометрия в координатах viewBox 24×24.
DOME_C = [12.0, 13.5]
DOME_R = 9.3
NEEDLE = [[12.0, 13.5], [16.7, 8.8]]
NEEDLE_W = 2.3
HUB_C = [12.0, 13.5]
HUB_R = 1.9
BASE = [8.0, 17.7, 16.0, 20.0] # x0, y0, x1, y1
BASE_R = 1.15

def in_dome?(x, y)
  dx = x - DOME_C[0]
  dy = y - DOME_C[1]
  y <= DOME_C[1] && (dx * dx + dy * dy) <= DOME_R * DOME_R
end

def dist_to_segment(x, y, a, b)
  vx = b[0] - a[0]
  vy = b[1] - a[1]
  wx = x - a[0]
  wy = y - a[1]
  t = (wx * vx + wy * vy) / (vx * vx + vy * vy)
  t = 0.0 if t.negative?
  t = 1.0 if t > 1.0
  px = a[0] + t * vx
  py = a[1] + t * vy
  Math.sqrt((x - px)**2 + (y - py)**2)
end

def in_needle?(x, y)
  dist_to_segment(x, y, NEEDLE[0], NEEDLE[1]) <= NEEDLE_W / 2
end

def in_hub?(x, y)
  (x - HUB_C[0])**2 + (y - HUB_C[1])**2 <= HUB_R * HUB_R
end

def in_base?(x, y)
  x0, y0, x1, y1 = BASE
  cx = (x0 + x1) / 2
  cy = (y0 + y1) / 2
  qx = (x - cx).abs - ((x1 - x0) / 2 - BASE_R)
  qy = (y - cy).abs - ((y1 - y0) / 2 - BASE_R)
  qx = 0 if qx.negative?
  qy = 0 if qy.negative?
  qx * qx + qy * qy <= BASE_R * BASE_R
end

def pixel_color(x, y)
  return WHITE if in_needle?(x, y) || in_hub?(x, y)
  return AMBER if in_dome?(x, y) || in_base?(x, y)

  nil
end

def write_png(size, path)
  scale = size / 24.0
  ss = 4
  rows = []
  size.times do |py|
    row = [0] # фильтр None
    size.times do |px|
      r = g = b = 0
      a = 0
      ss.times do |sy|
        ss.times do |sx|
          x = (px + (sx + 0.5) / ss) / scale
          y = (py + (sy + 0.5) / ss) / scale
          c = pixel_color(x, y)
          next if c.nil?

          r += c[0]
          g += c[1]
          b += c[2]
          a += 255
        end
      end
      n = ss * ss
      row << (r / n) << (g / n) << (b / n) << (a / n)
    end
    rows << row.pack('C*')
  end

  ihdr = [size, size, 8, 6, 0, 0, 0].pack('N5')
  idat = Zlib::Deflate.deflate(rows.join)
  chunk = lambda do |type, data|
    type = type.b
    [data.bytesize, type, data, Zlib.crc32(type + data)].pack('NA4A*N')
  end
  File.binwrite(path, +"\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', ihdr) +
                       chunk.call('IDAT', idat) + chunk.call('IEND', ''.b))
end

[16, 24].each do |size|
  path = File.join(ICON_DIR, "bench_#{size}.png")
  write_png(size, path)
  puts "written #{path}"
end
