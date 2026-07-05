# frozen_string_literal: true
# Parsing dell'output Minitest.
# Estratto da bin/calvin.rb — singola responsabilità.

module Calvin
  module TestOutputParser
    # Ritorna Float (es. 87.5) o nil se non parsabile.
    def self.pass_pct(output)
      return nil if output.nil? || output.empty?
      m = output.match(/(\d+) runs, (\d+) failures/)
      return nil unless m
      runs, failures = m[1].to_i, m[2].to_i
      return nil if runs.zero?
      ((runs - failures) / runs.to_f * 100).round(1)
    end
  end
end
