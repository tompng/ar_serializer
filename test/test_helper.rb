require 'simplecov'
SimpleCov.start 'test_frameworks'
$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'ar_serializer'
require_relative 'db'
require 'minitest/autorun'
unless User.table_exists?
  DB.migrate
  DB.seed
end

module SQLCounts
  module M
    # activerecord <= 7.0
    def exec_query(*args, **option)
      SQLCounts.increment_count
      super
    end
    # activerecord >= 7.1
    def internal_exec_query(*args, **option)
      SQLCounts.increment_count
      super
    end
  end
  def self.increment_count
    @count = count + 1
  end
  def self.count
    @count ||= 0
    return @count unless block_given?
    before = self.count
    out = yield
    after = self.count
    [after - before, out]
  end
  ActiveRecord::Base.connection.extend M
end
