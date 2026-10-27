# DN1Sup Benchmark

Расширение SketchUp, создано скаффолдом `ext_scaffold` (MCP-сервер `sketchup-dev`) 2026-10-28.

## Структура

```
dn1sup_benchmark.rb            регистратор (SketchupExtension + Extension Manager)
dn1sup_benchmark/
  main.rb                неймспейс Dn1supBenchmark: setup!/unload!/about
  command.rb             команды (пример: create_sample_box с undo-циклом)
  dialog.rb              HtmlDialog (если запрошен)
  test/test_helper.rb    мини-харнесс (run! / assert / skip)
  test/main_test.rb      тесты: юнит + живые (внутри SketchUp)
```

## Разработка с живой обратной связью (MCP sketchup-dev)

Один id, без dev-двойников: рабочая копия ставится в Plugins под тем же id,
распространение — через GitHub Releases (подробнее — AGENTS.md в корне).

1. Правка кода в этой папке (рабочая копия).
2. `ext_install id=dn1sup_benchmark` — поставить в Plugins (обновление — повторный вызов с force=true).
3. `ext_reload id=dn1sup_benchmark` — пересинхрон из рабочей копии и горячая перезагрузка одной командой.
4. `ext_test id=dn1sup_benchmark` — прогон тестов внутри SketchUp.
5. `view_png` — скриншот вида для визуальной проверки.
6. `ext_pack id=dn1sup_benchmark` — собрать .rbz релиза.

## Живые тесты

Меню Extensions → DN1Sup Benchmark → «Тесты (лог в Ruby Console)», либо ext_test.
Локально (без SketchUp): `ruby test/main_test.rb` — модельные тесты уйдут в skip.
