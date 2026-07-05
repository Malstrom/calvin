# frozen_string_literal: true
# Esegue la suite di test del repo target e parsa i failure Minitest.
#
# Uso:
#   result = Calvin::TestRunner.new(rails_root: "/path/to/synca/backend/api").run
#   result[:success]  # => true | false
#   result[:output]   # => String (stdout+stderr combinati)
#   result[:failures] # => Array<{ test_path:, impl_path:, message: }>
#
# rails_root deve essere il path assoluto della dir Rails di synca nel runner.
# Non lancia eccezioni: qualsiasi errore di sistema imposta success: false.

module Calvin
  class TestRunner
    # Cattura sia blocchi Failure: che Error: di Minitest.
    # Formato Minitest:
    #   Failure:
    #   TestClass#test_method [test/path/to_test.rb:42]:
    #   Expected ... / NoMethodError ...
    FAILURE_BLOCK_RE = /
      ^(?:Failure|Error):\n
      (\S+)\#(\S+)\s+\[([^:]+):(\d+)\]:\n
      (.*?)(?=\n(?:Failure|Error):\n|\n\d+\s+runs|\z)
    /mx.freeze

    # Convenzione Rails: test/X/foo_test.rb → app/X/foo.rb
    IMPL_PATH_MAP = {
      "test/contracts"   => "app/contracts",
      "test/services"    => "app/services",
      "test/controllers" => "app/controllers"
    }.freeze

    def initialize(rails_root:)
      @rails_root = rails_root
    end

    def run
      output, status = run_test_suite
      failures = status.success? ? [] : parse_failures(output)
      { success: status.success?, output: output, failures: failures }
    rescue => e
      Calvin::LOG.warn "TestRunner error: #{e.class} — #{e.message}"
      { success: false, output: e.message, failures: [] }
    end

    private

    def run_test_suite
      stdout_stderr = nil
      status        = nil
      Dir.chdir(@rails_root) do
        stdout_stderr, status = Open3.capture2e(
          { "RAILS_ENV" => "test" },
          "bundle", "exec", "rails", "test",
          "--no-plugins"
        )
      end
      [stdout_stderr, status]
    end

    def parse_failures(output)
      output.scan(FAILURE_BLOCK_RE).map do |_klass, _method, test_path, _line, message|
        impl_path = derive_impl_path(test_path)
        { test_path: test_path, impl_path: impl_path, message: message.strip }
      end.uniq { |f| f[:test_path] }
    end

    # Deriva l'impl_path dal test_path usando le convenzioni Rails.
    # Ritorna nil se nessuna convenzione corrisponde — il prompt builder lo gestisce.
    def derive_impl_path(test_path)
      IMPL_PATH_MAP.each do |test_prefix, impl_prefix|
        if test_path.start_with?("#{test_prefix}/")
          base = test_path.sub("#{test_prefix}/", "").sub(/_test\.rb$/, ".rb")
          return "#{impl_prefix}/#{base}"
        end
      end
      nil
    end
  end
end
