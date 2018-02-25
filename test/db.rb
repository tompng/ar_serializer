require 'benchmark'
require 'active_record'
require_relative 'model'

module DB
  DATABASE_CONFIG = {
    adapter: 'sqlite3',
    database: ENV['DATABASE_NAME'] || 'test/development.sqlite3',
    pool: 5,
    timeout: 5000
  }
  ActiveRecord::Base.establish_connection DATABASE_CONFIG
  ActiveRecord::Base.logger = Logger.new(STDOUT)

  def self.migrate
    File.unlink DATABASE_CONFIG[:database] if File.exist? DATABASE_CONFIG[:database]
    ActiveRecord::Base.clear_all_connections!
    ActiveRecord::Migration::Current.class_eval do
      create_table :users do |t|
        t.string :name
      end
      create_table :posts do |t|
        t.references :user
        t.string :title
        t.text :body
        t.timestamps
      end

      create_table :comments do |t|
        t.references :post
        t.references :user
        t.text :body
        t.timestamps
      end

      create_table :stars do |t|
        t.references :comment
        t.references :user
        t.timestamps
      end
    end
  end

  def self.seed
    users = 8.times.map do
      User.create! name: rand.to_s
    end
    posts = 16.times.map do
      Post.create! user: users.sample, title: rand.to_s, body: rand.to_s
    end
    comments = 32.times.map do
      Comment.create! post: posts.sample, user: users.sample, body: rand.to_s
    end
    64.times do
      Star.create! comment: comments.sample, user: users.sample
    end
  end
end
