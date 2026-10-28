# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/environment.rb — описание среды прогона.
#
# Собирает только то, что реально доступно через документированные источники.
# Каждой группе полей сопоставлен источник (environment.sources). Чего через
# SketchUp Ruby API не существует (GPU-движок, счётчики CPU/GPU/VRAM) —
# остаётся null с пометкой «нет источника», а не нулём.
# =============================================================================

module Dn1supBenchmark
  module Environment
    FPS_SOURCE = 'внутренний замер: счётчик кадров Tool#draw + view.invalidate ' \
                 '(Ruby-сторона; это не GPU-счётчик)'

    class << self
      def context(profile, params)
        exts = 0
        Sketchup.extensions.each { |e| exts += 1 if e.loaded? }
        {
          'schema_version' => 1,
          'benchmark_version' => Dn1supBenchmark::VERSION,
          'test_suite_version' => Runner::SUITE_VERSION,
          'extension_version' => Dn1supBenchmark::VERSION, # легаси-ключ 0.1.0
          'profile' => profile,
          'params' => params,
          'sketchup_version' => safe { Sketchup.version.to_s },
          'version_number' => safe { Sketchup.version_number.to_i },
          'ruby_version' => RUBY_VERSION,
          'ruby_description' => safe { RUBY_DESCRIPTION },
          'platform' => RUBY_PLATFORM,
          'os' => ENV['OS'].to_s,
          'cpu' => ENV['PROCESSOR_IDENTIFIER'].to_s,
          'cores' => ENV['NUMBER_OF_PROCESSORS'].to_i,
          'extensions_loaded' => exts,
          'started_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
          'environment' => graphics_context,
          'sources' => sources
        }
      end

      private

      # Параметры графики/окна, доступные через API; недоступное — null.
      def graphics_context
        model = safe { Sketchup.active_model }
        view = safe { model && model.active_view }
        ro = safe { model && model.rendering_options }
        {
          'ui_scale_factor' => safe { UI.scale_factor },
          'viewport' => {
            'width' => safe { view && view.vpwidth },
            'height' => safe { view && view.vpheight }
          },
          'render_mode' => safe { ro && ro['RenderMode'] },
          'face_style_mode' => safe { ro && ro['FaceStyleMode'] },
          'edge_display_mode' => safe { ro && ro['EdgeDisplayMode'] },
          'display_shadows' => safe { ro && ro['DisplayShadows'] },
          'graphics_engine' => nil,
          'graphics_engine_note' => 'SketchUp Ruby API не предоставляет сведений о GPU-движке'
        }
      end

      def sources
        {
          'sketchup_version' => 'Sketchup.version / version_number',
          'ruby_version' => 'RUBY_VERSION / RUBY_DESCRIPTION',
          'os' => 'ENV[OS], RUBY_PLATFORM',
          'cpu' => 'ENV[PROCESSOR_IDENTIFIER]',
          'cores' => 'ENV[NUMBER_OF_PROCESSORS]',
          'ui_scale_factor' => 'UI.scale_factor (масштаб DPI)',
          'viewport' => 'View#vpwidth / vpheight (логические пиксели)',
          'render_options' => 'Model#rendering_options',
          'graphics_engine' => 'нет источника — поле всегда null',
          'cpu_load' => 'нет источника — не измеряется',
          'gpu_vram' => 'нет источника — не измеряется',
          'fps' => FPS_SOURCE,
          'durations' => 'Process.clock_gettime(Process::CLOCK_MONOTONIC)'
        }
      end

      def safe
        yield
      rescue StandardError
        nil
      end
    end
  end
end
