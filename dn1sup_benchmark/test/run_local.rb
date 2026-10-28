# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/test/run_local.rb — локальный запуск юнит-тестов вне
# SketchUp (модельные тесты уходят в skip):
#   ruby -I dn1sup_benchmark/test/stubs dn1sup_benchmark/test/run_local.rb
# =============================================================================

dir = __dir__
Dir.glob(File.join(dir, '*_test.rb')).sort.each { |f| require File.expand_path(f) }
report = Dn1supBenchmark::Test.run!

puts "тестов: #{report['total']}, прошло: #{report['passed']}, " \
     "провалено: #{report['failures'].size}, пропущено: #{report['skipped'].size}, " \
     "#{report['duration_ms']} мс"
report['failures'].each do |f|
  puts "FAIL: #{f['name']}: #{f['error']}"
  Array(f['backtrace']).first(6).each { |line| puts "  #{line}" }
end
report['skipped'].each { |s| puts "skip: #{s['name']} (#{s['reason']})" }
exit(report['failures'].empty? ? 0 : 1)
