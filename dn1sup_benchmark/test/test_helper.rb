# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/test/test_helper.rb — мини-харнесс тестов «DN1Sup Benchmark».
#
# Работает в двух средах:
#   • внутри SketchUp — запуск через ext_test MCP-сервера sketchup-dev
#     (или пункт меню «Тесты»): живые тесты с активной моделью;
#   • в обычном Ruby — ruby test/main_test.rb: юнит-тесты логики
#     (модельные тесты помечаются skip вне SketchUp).
#
# Намеренно НЕ minitest/autorun: у него at_exit-хуки и накопление классов
# между повторными запусками в одном процессе SketchUp. Харнесс можно
# перезапускать сколько угодно (run! сам очищает список).
# =============================================================================

require_relative '../main' unless defined?(Dn1supBenchmark::VERSION)

module Dn1supBenchmark
  module Test
    class Failure < StandardError; end
    class Skip    < StandardError; end

    @tests = []

    class << self
      attr_reader :tests

      def test(name, &block)
        @tests << [name, block]
      end

      def assert(condition, msg = 'утверждение ложно')
        raise Failure, msg unless condition
      end

      def assert_equal(expected, actual, msg = nil)
        return if expected == actual

        raise Failure, "#{msg ? "#{msg}: " : ''}ожидали #{expected.inspect}, получили #{actual.inspect}"
      end

      def assert_nil(actual, msg = nil)
        assert(actual.nil?, "#{msg ? "#{msg}: " : ''}ожидали nil, получили #{actual.inspect}")
      end

      def assert_raises(*klasses)
        yield
        raise Failure, "ожидали исключение #{klasses.map(&:inspect).join('|')}, но блок завершился без ошибок"
      rescue Failure
        raise
      rescue StandardError => e
        assert(klasses.any? { |k| e.is_a?(k) },
               "ожидали #{klasses.map(&:inspect).join('|')}, получили #{e.class}: #{e.message}")
      end

      def refute(condition, msg = 'ожидали ложь')
        raise Failure, msg if condition
      end

      def skip(reason = 'пропуск')
        raise Skip, reason
      end

      # Выполняет все зарегистрированные тесты, возвращает хеш-отчёт и
      # очищает список (повторный run! стартует с чистого листа).
      # Ключи отчёта — СТРОЧНЫЕ: через мост (TCP/JSON) Symbol-ключи
      # превращаются в ":total" и клиент их не находит.
      def run!
        results = { 'total' => @tests.size, 'failures' => [], 'skipped' => [] }
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @tests.each do |name, block|
          begin
            block.call
          rescue Skip => e
            results['skipped'] << { 'name' => name, 'reason' => e.message }
          rescue Failure => e
            results['failures'] << { 'name' => name, 'error' => e.message }
          rescue Exception => e # rubocop:disable Lint/RescueException
            results['failures'] << { 'name' => name, 'error' => "#{e.class}: #{e.message}",
                                     'backtrace' => Array(e.backtrace).first(5) }
          end
        end
        results['duration_ms'] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
        results['passed'] = results['total'] - results['failures'].size - results['skipped'].size
        reset!
        results
      end

      def reset!
        @tests = []
      end
    end
  end
end
