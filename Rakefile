# frozen_string_literal: true
# Task di sviluppo di Calvin.
#
#   bundle exec rake test      unit test (test/**/*_test.rb)
#   bundle exec rake lint      rubocop su lib/, bin/, test/
#   bundle exec rake           test + lint
#
# Il Gemfile vive in bin/ (è quello che il workflow installa), quindi da root:
#   BUNDLE_GEMFILE=bin/Gemfile bundle exec rake

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs    << "lib" << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
  t.verbose = false
end

desc "rubocop su lib, bin e test"
task :lint do
  sh "rubocop lib bin test Rakefile"
end

task default: %i[test lint]
