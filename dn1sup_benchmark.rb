# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark.rb — регистратор расширения «DN1Sup Benchmark» (единственный файл в корне
# Plugins). SketchUp автозагружает top-level .rb при старте; весь код лежит
# рядом в подпапке dn1sup_benchmark/.
#
# Регистратор идемпотентен: повторный load (горячая перезагрузка через
# ext_reload) не дублирует запись в Extension Manager — main.rb при этом
# загружается отдельным load (см. ext_reload MCP-сервера sketchup-dev).
# =============================================================================

require 'sketchup.rb'
require 'extensions.rb'

# ExtensionManager не включает Enumerable — только each/[]/size.
_registered = false
Sketchup.extensions.each { |e| _registered = true if e.name == "DN1Sup Benchmark" }

unless _registered
  ext = SketchupExtension.new("DN1Sup Benchmark", File.join('dn1sup_benchmark', 'main'))
  ext.description = "Бенчмарк производительности SketchUp: чистый Ruby, API (геометрия, компоненты, атрибуты, транзакции), файловые операции, FPS вьюпорта. Профили small/medium/large, HTML-панель, сравнение прогонов."
  ext.version     = '0.3.0'
  ext.creator     = "dn1desn"
  ext.copyright   = '2026, dn1desn'
  Sketchup.register_extension(ext, true) # true = загружать при старте SketchUp
end
