require 'test_helper'
require 'open3'

class LazyLoadTest < Minitest::Test
  SCRIPT = <<~'RUBY'
    require 'ar_serializer'
    puts "base_loaded_after_require=#{ActiveRecord.autoload?(:Base).nil?}"
    puts "serializable=#{ActiveRecord::Base.include?(ArSerializer::Serializable)}"
    puts "array_like=#{ActiveRecord::Relation.include?(ArSerializer::ArrayLikeSerializable)}"
  RUBY

  def test_require_defers_includes_until_active_record_base_loads
    lib = File.expand_path('../lib', __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, '-I', lib, '-e', SCRIPT)
    assert status.success?, out
    assert_includes out, 'base_loaded_after_require=false'
    assert_includes out, 'serializable=true'
    assert_includes out, 'array_like=true'
  end
end
