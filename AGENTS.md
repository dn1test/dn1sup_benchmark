# AGENTS.md — DN1Sup Benchmark

> **ОБЯЗАТЕЛЬНО ПРОЧИТАТЬ ПЕРЕД РАБОТОЙ — общие правила разработки:**
> мастер `U:\dn1code\sketchup_ext\AGENTS.md` — единственная полная копия
> (публикация: `U:\dn1code\sketchup_ext\PUBLISHING.md`).

- Расширение: `dn1sup_benchmark` / имя: «DN1Sup Benchmark».
- Критичное: один id без `_dev`-двойников; версию поднимать сразу в двух
  местах (`ext.version` регистратора и `VERSION` в main.rb, `registry.json`);
  релиз — только при зелёных тестах. Локальный чек-лист публикации — в
  `PUBLISHING.md` этого репозитория.
- Dev-цикл — через MCP sketchup-dev (мост к живому SketchUp): `ext_check` →
  `ext_install` → `ext_reload` → `ext_test`; в вызовах передавать
  `dir=U:/dn1code/sketchup_ext/dn1sup_benchmark` (корень этой папки —
  структура совместима с dev_root: `<root>/<id>/`).
- Методика бенчмарка (monotonic-таймер, медианы, undo-откат сцен,
  FPS через Tool#draw + view.invalidate) — в README; менять методику можно
  только с bump минорной версии: результаты должны быть сравнимы между
  прогонами одной минорной версии.
