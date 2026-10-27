# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/report.rb — сохранение результатов и HTML-отчёты.
#
# Файлы кладутся в ~/Documents/SketchUp Benchmarks/:
#   bench-SU<версия>__<профиль>_<дата>.json — сырые данные прогона;
#   bench-SU<версия>__<профиль>_<дата>.html — одиночный отчёт;
#   compare-<дата>.html — сравнение нескольких прогонов (Report.compare).
# HTML самодостаточный: inline CSS + SVG-бары, без CDN/интернета.
# =============================================================================

require 'json'

module Dn1supBenchmark
  module Report
    COLORS = {
      'scene_gen' => '#5e81ac', 'viewport' => '#a3be8c', 'hierarchy' => '#ebcb8b',
      'editing' => '#d08770', 'textures' => '#b48ead'
    }.freeze

    class << self
      def report_dir
        docs = File.join(ENV['USERPROFILE'] || ENV['HOME'] || Dir.tmpdir, 'Documents')
        dir = File.join(docs, 'SketchUp Benchmarks')
        PngGen.mkdir_p(dir)
        dir
      end

      def save_run(data)
        dir = report_dir
        su = data['meta']['sketchup_version'].to_s.split('.').first
        tag = "SU#{su}__#{data['meta']['profile']}__#{Time.now.strftime('%Y%m%d-%H%M%S')}"
        json_path = File.join(dir, "bench-#{tag}.json")
        html_path = File.join(dir, "bench-#{tag}.html")
        File.write(json_path, JSON.pretty_generate(data))
        File.write(html_path, html_single(data))
        { 'json' => json_path, 'html' => html_path }
      end

      # Сравнение прогонов: runs — массив data-хешей (или путей к JSON).
      # Базовый — первый; у каждой колонки % к базе.
      def compare(runs, out_path = nil)
        datas = runs.map { |r| r.is_a?(String) ? JSON.parse(File.read(r)) : r }
        raise 'нужно минимум 2 прогона' if datas.size < 2

        out_path ||= File.join(report_dir, "compare-#{Time.now.strftime('%Y%m%d-%H%M%S')}.html")
        File.write(out_path, html_compare(datas))
        { 'html' => out_path, 'runs' => datas.size }
      end

      # ---------------------------------------------------------------- single

      def html_single(data)
        meta = data['meta']
        results = data['results'] || []
        groups = results.group_by { |r| r['group'] }
        b = +"<html lang=\"ru\">\n<head>\n<meta charset=\"utf-8\">\n"
        b << "<title>Бенчмарк SketchUp — SU#{meta['sketchup_version']}</title>\n"
        b << css
        b << "</head>\n<body>\n"
        b << "<h1>Бенчмарк производительности SketchUp</h1>\n"
        b << meta_table(meta)
        groups.keys.each do |g|
          b << group_section(g, groups[g])
        end
        errs = results.select { |r| r['error'] }
        unless errs.empty?
          b << "<h2>Ошибки тестов</h2>\n<ul>\n"
          errs.each { |r| b << "<li><code>#{esc(r['id'])}</code>: #{esc(r['error'])}</li>\n" }
          b << "</ul>\n"
        end
        b << "<p class=\"muted\">Сгенерировано dn1sup_benchmark v#{meta['extension_version']}. "
        b << "Меньше мс — лучше; больше FPS — лучше.</p>\n</body>\n</html>\n"
        b
      end

      def meta_table(meta)
        rows = [
          ['SketchUp', "SU #{meta['sketchup_version']} (#{meta['version_number']})"],
          ['Ruby', meta['ruby_version']],
          ['Профиль', meta['profile']],
          ['Начало прогона', meta['started_at']],
          ['CPU', "#{meta['cpu']} × #{meta['cores']} ядер"],
          ['Платформа', meta['platform']],
          ['Загружено расширений', meta['extensions_loaded']]
        ]
        out = +"<table class=\"meta\">\n"
        rows.each { |k, v| out << "<tr><th>#{esc(k)}</th><td>#{esc(v)}</td></tr>\n" }
        out << "</table>\n"
        out
      end

      def group_section(group, results)
        title = Runner::GROUP_TITLES.fetch(group, group)
        color = COLORS.fetch(group, '#888888')
        out = +"<h2>#{esc(title)}</h2>\n<table class=\"bench\">\n"
        out << "<tr><th>Тест</th><th class=\"num\">Значение</th><th class=\"num\">min</th>"
        out << "<th class=\"num\">max</th><th>Диаграмма</th><th>Сущностей</th></tr>\n"
        max = results.map { |r| r['value'].to_f }.compact.max
        max = 0.0 if max.nil? || max <= 0
        results.each do |r|
          val = r['value']
          out << "<tr#{r['error'] ? " class=\"err\"" : ''}>"
          out << "<td>#{esc(r['name'] || r['id'])}#{r['error'] ? " <span class=\"muted\">(ошибка)</span>" : ''}</td>"
          if val
            out << "<td class=\"num\"><b>#{fmt(val, r['unit'])}</b></td>"
            out << "<td class=\"num\">#{fmt(r['min'], r['unit'])}</td>"
            out << "<td class=\"num\">#{fmt(r['max'], r['unit'])}</td>"
            out << "<td>#{bar(val, max, color, r['unit'] == 'fps')}</td>"
          else
            out << "<td class=\"num muted\">—</td><td class=\"num muted\">—</td>"
            out << "<td class=\"num muted\">—</td><td class=\"muted\">—</td>"
          end
          out << "<td class=\"num\">#{r['entities']}</td></tr>\n"
        end
        out << "</table>\n"
        out
      end

      def bar(value, max, color, higher)
        return '' if max <= 0

        frac = higher ? value / max : (max - value) / max # «зелёнее» — ближе к лучшему
        frac = 0.0 if frac < 0
        w = (frac * 180).round
        "<svg width=\"200\" height=\"14\" xmlns=\"http://www.w3.org/2000/svg\">" \
          "<rect x=\"0\" y=\"3\" width=\"180\" height=\"8\" fill=\"#e5e5e5\" rx=\"2\"/>" \
          "<rect x=\"0\" y=\"3\" width=\"#{w}\" height=\"8\" fill=\"#{color}\" rx=\"2\"/>" \
          "</svg>"
      end

      # --------------------------------------------------------------- compare

      def html_compare(datas)
        base = datas.first
        cols = datas.map { |d| "SU#{d['meta']['sketchup_version']}" }
        ids = []
        datas.each do |d|
          (d['results'] || []).each { |r| ids << r['id'] unless ids.include?(r['id']) }
        end
        by_run_test = datas.map do |d|
          h = {}
          (d['results'] || []).each { |r| h[r['id']] = r }
          h
        end

        b = +"<html lang=\"ru\">\n<head>\n<meta charset=\"utf-8\">\n"
        b << "<title>Сравнение версий SketchUp</title>\n" << css << "</head>\n<body>\n"
        b << "<h1>Сравнение версий SketchUp</h1>\n"
        b << "<p class=\"muted\">База — #{esc(cols.first)}. Зелёным — лучше базы, "
        b << "красным — хуже (порог ±3%). Меньше мс — лучше; больше FPS — лучше.</p>\n"
        b << meta_table(base['meta'])

        groups = {}
        ids.each do |tid|
          r = by_run_test.find { |h| h[tid] && h[tid]['group'] }
          groups[r[tid]['group']] ||= []
          groups[r[tid]['group']] << tid
        end

        groups.keys.each do |g|
          b << "<h2>#{esc(Runner::GROUP_TITLES.fetch(g, g))}</h2>\n"
          b << "<table class=\"bench compare\">\n<tr><th>Тест</th>"
          cols.each { |c| b << "<th class=\"num\">#{esc(c)}</th>" }
          b << "</tr>\n"
          groups[g].each do |tid|
            base_r = by_run_test.first[tid]
            name = base_r ? (base_r['name'] || tid) : tid
            unit = base_r ? base_r['unit'] : nil
            higher = base_r ? base_r['higher_is_better'] : false
            b << "<tr><td>#{esc(name)}</td>"
            datas.each_with_index do |_d, i|
              r = by_run_test[i][tid]
              if r.nil? || r['value'].nil?
                b << "<td class=\"num muted\">—</td>"
                next
              end
              cell = fmt(r['value'], unit)
              unless i.zero?
                basev = by_run_test.first[tid] && by_run_test.first[tid]['value']
                if basev && basev > 0
                  rel = (r['value'] / basev - 1) * 100
                  cls = rel.abs < 3 ? 'same' : (higher ? (rel > 0 ? 'better' : 'worse') : (rel < 0 ? 'better' : 'worse'))
                  cell << " <span class=\"#{cls}\">#{rel >= 0 ? '+' : ''}#{rel.round(1)}%</span>"
                end
              end
              b << "<td class=\"num#{i.zero? ? ' base' : ''}\">#{cell}</td>"
            end
            b << "</tr>\n"
          end
          b << "</table>\n"
        end
        b << "</body>\n</html>\n"
        b
      end

      # ------------------------------------------------------------------ misc

      def fmt(v, unit)
        return '—' if v.nil?

        if unit == 'fps'
          "#{v.to_f.round(1)} fps"
        else
          v.to_f >= 1000 ? "#{(v.to_f / 1000).round(2)} с" : "#{v.to_f.round(1)} мс"
        end
      end

      def esc(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      def css
        <<~CSS
          <style>
          body { font-family: "Segoe UI", Arial, sans-serif; margin: 24px auto; max-width: 980px;
                 color: #2e3440; background: #fbfbfd; }
          h1 { font-size: 22px; } h2 { font-size: 17px; margin: 26px 0 8px; color: #3b4252; }
          table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 13px; }
          th, td { border: 1px solid #dfe1e6; padding: 5px 9px; text-align: left; vertical-align: middle; }
          th { background: #eceff4; font-weight: 600; }
          table.meta { width: auto; min-width: 420px; }
          table.meta th { width: 180px; }
          td.num, th.num { text-align: right; white-space: nowrap; }
          tr.err td { background: #f7e3e3; }
          .muted { color: #7b8394; font-size: 12px; }
          .base { background: #f2f4f8; }
          .better { color: #2e7d32; font-size: 11px; }
          .worse { color: #c62828; font-size: 11px; }
          .same { color: #7b8394; font-size: 11px; }
          </style>
        CSS
      end
    end
  end
end
