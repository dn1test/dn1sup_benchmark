# frozen_string_literal: true
# dn1sup_benchmark/test/wave_tool_test.rb — математика волны и начальное
# состояние инструмента (живой рендер-луп проверяется реальным прогоном).

require_relative 'test_helper'

module Dn1supBenchmark::Test
  W = Dn1supBenchmark::WaveTool

  test 'волна: периодичность по времени' do
    x = 250.0
    y = 130.0
    a = W.wave_z(x, y, 0.0)
    b = W.wave_z(x, y, W::PERIOD_S)
    assert((a - b).abs < 1e-9, 'через период фаза должна повторяться')
  end

  test 'волна: амплитуда не превышает заданную' do
    # перебор сетки времени и координат
    max = 0.0
    0.step(3.0, 0.05) do |t|
      (0..20).each do |k|
        x = k * 100.0
        y = (20 - k) * 100.0
        z = W.wave_z(x, y, t)
        max = z.abs if z.abs > max
      end
    end
    assert(max <= W::AMPLITUDE_MM + 1e-6, "амплитуда #{max} превысила #{W::AMPLITUDE_MM}")
    assert(max > W::AMPLITUDE_MM * 0.99, 'волна должна достигать амплитуды')
  end

  test 'волна: бегущая (сдвиг фазы со временем на одном месте)' do
    x = 400.0
    y = 200.0
    refute((W.wave_z(x, y, 0.1) - W.wave_z(x, y, 0.4)).abs < 1e-9,
           'в одной точке поверхность должна двигаться')
  end

  test 'WaveTool: начальное состояние и stop_now без activate' do
    tool = W.new(2.0, [], [])
    assert_nil(tool.result, 'результата до замера быть не должно')
    assert_nil(tool.stop_now, 'stop_now без activate возвращает nil')
  end

  test 'WaveTool: константы зафиксированы (методика)' do
    assert_equal(100.0, W::CELL_MM, 'куб 100 мм — из ТЗ')
    assert_equal(300.0, W::AMPLITUDE_MM, 'амплитуда 300 мм')
    assert_equal(8.0, W::WAVELENGTH_CELLS, 'длина волны 8 клеток')
    assert_equal(3.0, W::PERIOD_S, 'период 3 с')
  end
end
