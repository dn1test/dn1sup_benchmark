# Публикация расширения на GitHub

> Полная общая инструкция — мастер `U:\dn1code\sketchup_ext\PUBLISHING.md`
> (единственная полная копия: как Store ищет репозитории, обязательные
> требования, registry.json, версии и changelog, релизы). Ниже — локальный
> чек-лист этого репозитория.

## Чек-лист этого репозитория

| Требование | Статус |
|---|---|
| Имя `dn1sup_*` в аккаунте `dn1test` | ⏳ `dn1test/dn1sup_benchmark` (репозиторий создать) |
| Не archived | ⏳ после создания |
| `registry.json` в корне `main` | ✅ (id, name, description, version 0.1.0) |
| Стабильные релизы с `.rbz` | ✅ `dist/…rbz` через CI (`ruby tools/pack.rb`) |
| Теги `vMAJOR.MINOR.PATCH` | ✅ (workflow на `v*`) |
| Регистратор `<id>.rb` + `ext.id` | ✅ `dn1sup_benchmark.rb` в корне |

## Сборка и проверки перед релизом

```
ruby tools/pack.rb        # dist/dn1sup_benchmark-<ver>.rbz
```

Dev-цикл в живом SketchUp — через MCP sketchup-dev с параметром
`dir=U:/dn1code/sketchup_ext/dn1sup_benchmark`: `ext_check` → `ext_install` →
`ext_reload` → `ext_test` (зелёные тесты обязательны). У расширения нет
frontend-сборки — пересобирать перед коммитом нечего.
