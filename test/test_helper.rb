$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'ar_serializer'
require_relative 'db'
require 'minitest/autorun'
unless User.table_exists?
  DB.migrate
  DB.seed
end
