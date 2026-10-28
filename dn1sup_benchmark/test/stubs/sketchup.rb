# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/test/stubs/sketchup.rb — минимальная заглушка SketchUp API
# для ЛОКАЛЬНОГО прогона юнит-тестов вне SketchUp:
#   ruby -I dn1sup_benchmark/test/stubs dn1sup_benchmark/test/main_test.rb
# Модельные тесты в заглушке уходят в skip (Sketchup.active_model => nil).
# =============================================================================

module Sketchup
  def self.extensions
    [].each
  end

  def self.version
    '0.0.0'
  end

  def self.version_number
    0
  end

  def self.active_model; nil; end
end

module UI
  # Заглушка меню: setup! может строить пункты — они никуда не идут.
  class MenuStub
    def add_submenu(_name); self; end
    def add_item(_name); self; end
    def add_separator; self; end
  end

  def self.menu(_name); MenuStub.new; end

  def self.scale_factor; 1.0; end
end
