# frozen_string_literal: true
# Inietta il contesto di test nel prompt: testing.yml, test_helper,
# support files, controller test di esempio, fixture dei model toccati.
# Estratto da implement_flow.rb — singola responsabilità.
#
# Uso:
#   Calvin::TestContextInjector.build(paths:, github:) → String
#   Ritorna stringa vuota se non ci sono file da iniettare.

module Calvin
  module TestContextInjector
    TESTING_YML_PATH        = ".calvin/testing.yml"
    TEST_HELPER_PATH        = "test/test_helper.rb"
    TEST_SUPPORT_DIR        = "test/support"
    CONTROLLER_TEST_EXAMPLE = "test/controllers/api/v1/me_controller_test.rb"
    MODEL_PATH_PATTERN      = %r{app/models/([\w/]+)\.rb}

    def self.build(paths:, github:)
      blocks = []

      # 1. testing.yml
      if (yml = github.get_file_content(TESTING_YML_PATH))
        Calvin::LOG.info "TestContextInjector: injecting #{TESTING_YML_PATH}"
        blocks << "---\n#{TESTING_YML_PATH}\n#{yml}\n---"
      else
        Calvin::LOG.warn "TestContextInjector: #{TESTING_YML_PATH} non trovato"
      end

      # 2. test_helper.rb
      if (helper = github.get_file_content(TEST_HELPER_PATH))
        Calvin::LOG.info "TestContextInjector: injecting #{TEST_HELPER_PATH}"
        blocks << "---\n#{TEST_HELPER_PATH}\n#{helper}\n---"
      end

      # 3. test/support/*.rb
      github.list_directory(TEST_SUPPORT_DIR)
            .select { |name| name.end_with?(".rb") }
            .each do |name|
        path    = "#{TEST_SUPPORT_DIR}/#{name}"
        content = github.get_file_content(path)
        next unless content
        Calvin::LOG.info "TestContextInjector: injecting #{path}"
        blocks << "---\n#{path}\n#{content}\n---"
      end

      # 4. Controller test di esempio (se il task tocca controller)
      if paths.any? { |p| p.include?("test/controllers") }
        if (example = github.get_file_content(CONTROLLER_TEST_EXAMPLE))
          Calvin::LOG.info "TestContextInjector: injecting controller example #{CONTROLLER_TEST_EXAMPLE}"
          blocks << "---\nEXAMPLE — copy this exact pattern for controller tests:\n#{CONTROLLER_TEST_EXAMPLE}\n#{example}\n---"
        end
      end

      # 5. Fixture dei model toccati
      paths.each do |path|
        match = path.match(MODEL_PATH_PATTERN)
        next unless match
        table_name   = match[1].gsub("/", "_") + "s"
        fixture_path = "test/fixtures/#{table_name}.yml"
        content      = github.get_file_content(fixture_path)
        unless content
          Calvin::LOG.warn "TestContextInjector: fixture non trovata: #{fixture_path}"
          next
        end
        Calvin::LOG.info "TestContextInjector: injecting fixture #{fixture_path}"
        blocks << "---\n#{fixture_path}\n#{content}\n---"
      end

      return "" if blocks.empty?
      "\n\n## TEST CONTEXT (read carefully before writing any test)\n\n" + blocks.join("\n\n")
    end
  end
end
