require "test_helper"

class ArSerializerTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::ArSerializer::VERSION
  end

  def test_field
    post = Post.first
    assert_equal(
      { title: post.title, body: post.body },
      ArSerializer.serialize(post, [:title, :body])
    )
  end

  def test_namespace
    user = User.first
    assert_raises(ArSerializer::InvalidQuery) { ArSerializer.serialize user, :bar }
    assert_equal({ bar: :bar }, ArSerializer.serialize(user, :bar, use: :aaa))
    assert_equal({ bar: :bar }, ArSerializer.serialize(user, :bar, use: :bbb))
    assert_equal({ foo: :foo1 }, ArSerializer.serialize(user, :foo, use: :bbb))
    assert_equal({ foo: :foo2 }, ArSerializer.serialize(user, :foo, use: :aaa))
    assert_equal({ foo: :foo2, foobar: :foobar }, ArSerializer.serialize(user, [:foo, :foobar], use: [:aaa, :bbb]))
  end

  def test_field_specify_modes
    post = Post.first
    expected = { title: post.title }
    queries = [
      :title,
      [:title],
      { title: {} },
      { title: true },
      { attributes: :title },
      { attributes: [:title] },
      { attributes: { title: {} } },
      { attributes: { title: true } }
    ]
    queries.each do |query|
      assert_equal expected, ArSerializer.serialize(post, query)
    end
  end

  def test_children
    user = Post.first.user
    expected = {
      name: user.name,
      posts: user.posts.map { |p| { title: p.title } }
    }
    assert_equal expected, ArSerializer.serialize(user, [:name, posts: :title])
  end

  def test_context
    star = Star.first
    user = star.user
    post = star.comment.post
    expected = {
      comments: post.comments.map do |c|
        { current_user_stars: c.stars.where(user: user).map { |s| { id: s.id } } }
      end
    }
    data = ArSerializer.serialize(
      post,
      { comments: { current_user_stars: :id } },
      context: { current_user: user }
    )
    assert_equal expected, data
  end

  def test_custom_preloader
    post = Star.first.comment.post
    expected = {
      comments: post.comments.map do |c|
        { stars_count_x5: c.stars.count * 5 }
      end
    }
    assert_equal expected, ArSerializer.serialize(post, { comments: :stars_count_x5 })
  end

  def test_preloader_arity
    klass = Class.new do
      def id; 'a'; end
      include ArSerializer::Serializable
      serializer_field :a1, preload: ->(as) { Hash.new [as[0].id] }
      serializer_field :a2, preload: ->(as, ctx) { Hash.new [as[0].id, ctx] }
      serializer_field :key1, preload: ->(as, x: 1){ Hash.new [as[0].id, x] }
      serializer_field :key2, preload: ->(as, ctx, x: 1) { Hash.new [as[0].id, ctx, x] }
      serializer_field :keyreq1, preload: ->(as, x:){ Hash.new [as[0].id, x] }
      serializer_field :keyreq2, preload: ->(as, ctx, x:) { Hash.new [as[0].id, ctx, x] }
      serializer_field :keyrest1, preload: ->(as, **params) { Hash.new [as[0].id, params] }
      serializer_field :keyrest2, preload: ->(as, ctx, **params) { Hash.new [as[0].id, ctx, params] }
    end
    params = { params: { x: 1 } }
    result = ArSerializer.serialize(
      klass.new,
      [
        :a1,
        :a2,
        :key1,
        :key2,
        keyreq1: params,
        keyreq2: params,
        keyrest1: params,
        keyrest2: params
      ],
      context: :ctx
    )
    expected1 = ['a']
    expected2 = ['a', :ctx]
    expectedkey1 = ['a', 1]
    expectedkey2 = ['a', :ctx, 1]
    expected = {
      a1: expected1,
      a2: expected2,
      key1: expectedkey1,
      key2: expectedkey2,
      keyreq1: expectedkey1,
      keyreq2: expectedkey2,
      keyrest1: ['a', { x: 1 }],
      keyrest2: ['a', :ctx, { x: 1 }]
    }
    assert_equal expected, result
  end

  def test_count_preloader
    post = Star.first.comment.post
    expected = {
      comments: post.comments.map do |c|
        { stars_count: c.stars.count }
      end
    }
    assert_equal expected, ArSerializer.serialize(post, { comments: :stars_count })
  end

  def test_association_option
    post = Comment.first.post
    query1 = { comments: :id }
    query2 = { cmnts: [:id, as: :comments] }
    assert_equal ArSerializer.serialize(post, query1), ArSerializer.serialize(post, query2)
  end

  def test_alias_column
    post = Comment.first.post
    expected = {
      TITLE: post.title,
      body: post.body,
      COMMENTS: post.comments.map do |c|
        {
          id: c.id,
          BODY: c.body
        }
      end
    }
    query = [
      :body,
      title: { as: :TITLE },
      comments: {
        as: :COMMENTS,
        attributes: [
          :id,
          body: { as: :BODY }
        ]
      }
    ]
    assert_equal expected, ArSerializer.serialize(post, query)
  end

  def test_dup_alias
    users = User.all
    expected = users.map { |u| { id1: u.id, id2: u.id, name1: u.name, name2: u.name } }
    query = [
      { id: { as: :id1 } }, { id: { as: :id2 } },
      { name: { as: :name1 } }, { name: { as: :name2 } }
    ]
    assert_equal expected, ArSerializer.serialize(users, query)
  end

  def test_as_field_alias
    users = User.all
    query1 = [
      { id: { as: :id1 } }, { id: { as: :id2 } },
      { name: { as: :name1 } }, { name: { as: :name2 } }
    ]
    query2 = [
      { id1: { field: :id } }, { id2: { field: :id } },
      { name1: { field: :name } }, { name2: { field: :name } }
    ]
    assert_equal ArSerializer.serialize(users, query1), ArSerializer.serialize(users, query2)
  end

  def test_query_count
    user = Star.first.comment.post.user
    query = {
      posts: {
        comments: [
          :stars_count,
          :stars_count_x5,
          user: :name,
          stars: { user: :name },
          current_user_stars: :id
        ]
      }
    }
    context = { current_user: Star.first.user }
    count, _result = SQLCounts.count do
      ArSerializer.serialize(user, query, context: context)
    end
    assert_equal 8, count
  end

  def test_association_params
    user = Comment.first.post.user
    expected = { posts: user.posts.map { |p| { comments: p.comments.order(body: :asc).limit(1).map { |c| { id: c.id } } } } }
    query = { posts: { comments: [:id, params: { limit: 1, order: { body: :asc } }] } }
    data = ArSerializer.serialize user, query
    assert_equal expected, data
    data2 = ArSerializer.serialize user, JSON.parse(query.to_json)
    assert_equal data, data2
  end

  def test_order_restriction
    query = {
      posts: [
        :id,
        params: { order: { created_at: :desc }}
      ]
    }
    ArSerializer.serialize User.all, query, use: :aaa
    assert_raises(ArSerializer::InvalidQuery) do
      ArSerializer.serialize User.all, query
    end
  end

  def test_accept_primary_key_ordering
    post_without_id_class = Class.new ActiveRecord::Base do
      self.table_name = :posts
      serializer_field :title
    end
    user_class = Class.new ActiveRecord::Base do
      self.table_name = :users
      has_many :posts, anonymous_class: post_without_id_class, foreign_key: :user_id
      serializer_field :name, :posts
    end
    [
      [:name, posts: :title],
      [:name, posts: [:title, params: { order: :desc }]],
      [:name, posts: [:title, params: { order: { id: :asc } }]]
    ].each do |query|
      assert ArSerializer.serialize(user_class.all, query)
    end
    assert_raises(ArSerializer::InvalidQuery) do
      query = [:name, posts: [:title, params: { order: { body: :asc } }]]
      ArSerializer.serialize user_class.all, query
    end
  end

  def test_reject_unorderable_key_ordering
    post_class = Class.new ActiveRecord::Base do
      self.table_name = :posts
      serializer_field :title, :createdAt
      serializer_field :body, orderable: false
    end
    user_class = Class.new ActiveRecord::Base do
      self.table_name = :users
      has_many :posts, anonymous_class: post_class, foreign_key: :user_id
      serializer_field :posts
      serializer_field :postsExceptCreatedAt, association: :posts, only: [:title, :body]
      serializer_field :postsOnlyTitle, association: :posts, only: :title
    end
    assert ArSerializer.serialize(user_class.all, { posts: [:title, :body, params: { order: { title: :asc } }] })
    assert ArSerializer.serialize(user_class.all, { posts: [:title, params: { order: { createdAt: :asc } }] })
    assert ArSerializer.serialize(user_class.all, { postsExceptCreatedAt: [:title, params: { order: { title: :asc } }] })
    assert ArSerializer.serialize(user_class.all, { postsOnlyTitle: [:title, params: { order: { title: :asc } }] })
    assert_raises(ArSerializer::InvalidQuery) do
      ArSerializer.serialize user_class.all, { posts: [:title, :body, params: { order: { body: :asc } }] }
    end
    assert_raises(ArSerializer::InvalidQuery) do
      ArSerializer.serialize user_class.all, { postsExceptCreatedAt: [:title, params: { order: { createdAt: :asc } }] }
    end
    assert_raises(ArSerializer::InvalidQuery) do
      ArSerializer.serialize user_class.all, { postsOnlyTitle: [:title, params: { order: { body: :asc } }] }
    end
  end


  def test_subclasses
    klass = Class.new User do
      self.table_name = :users
      serializer_field(:gender) { id.even? ? :male : :female }
    end
    name_output1 = ArSerializer.serialize(User.first, :name)
    name_output2 = ArSerializer.serialize(klass.first, :name)
    assert_equal name_output1, name_output2
    gender_output = ArSerializer.serialize klass.first, :gender
    assert_equal({ gender: :female }, gender_output)
    assert_raises(ArSerializer::InvalidQuery) { ArSerializer.serialize User.first, :gender }
  end

  def test_only_excepts
    ok_post_queries = [
      [User.all, { posts_only_title: :title }],
      [User.all, { posts_only_body: :body }],
      [Post.all, { user_only_name: :name }],
      [Post.all, { user_except_posts: :name }]
    ]
    error_post_queries = [
      [User.all, { posts_only_title: :body }],
      [User.all, { posts_only_body: :title }],
      [Post.all, { user_only_name: :posts }],
      [Post.all, { user_except_posts: :posts }]
    ]
    ok_post_queries.each do |target, query|
      ArSerializer.serialize target, query
    end
    error_post_queries.each do |target, query|
      assert_raises ArSerializer::InvalidQuery, query do
        ArSerializer.serialize target, query
      end
    end
  end

  def test_aster_only_except
    post = Post.first
    ['*', :*].each do |aster|
      data = ArSerializer.serialize post, { user: aster }
      data1 = ArSerializer.serialize post, { user_except_posts: aster }
      data2 = ArSerializer.serialize post, { user_only_name: aster }
      assert_equal post.user.name, data[:user][:name]
      assert_equal post.user.name, data1[:user_except_posts][:name]
      assert_equal post.user.name, data2[:user_only_name][:name]
      assert data[:user].keys.size > 2
      assert_equal data[:user].keys - [:posts], data1[:user_except_posts].keys
      assert_equal [:name], data2[:user_only_name].keys
    end
  end

  def test_order_by_camelized_field
    user_id = Post.group(:user_id).count.max_by(&:last).first
    user = User.find user_id
    { modifiedAt: :updated_at, createdAt: :created_at }.each do |field, column|
      get_target_ids = lambda do
        ArSerializer.serialize(
          user.reload,
          { posts: [:id, field, params: { order: { field => :asc } }] }
        )[:posts].map { |post| post[:id] }
      end
      user.posts.each do |post|
        post.update column => rand.days.ago
      end
      assert_equal user.posts.order(column => :asc).ids, get_target_ids.call
    end
  end

  def test_camelized_association
    posts = ArSerializer.serialize Post.all, { Comments: :id, comments: :id }
    assert(posts.all? { |post| post[:comments] == post[:Comments] })
  end

  def test_non_array_composite_value
    output = ArSerializer.serialize User.all, { posts_with_total: [:id, params: { limit: 2 }] }
    output_ref = ArSerializer.serialize User.all, { posts: :id }
    result = output.zip(output_ref).all? do |o, oref|
      posts_with_total = o[:posts_with_total]
      posts = oref[:posts]
      posts_with_total[:total] == posts.size && posts_with_total[:list] == posts.take(2)
    end
    assert result
  end

  def test_type_validation
    serializable_class = Class.new { include ArSerializer::Serializable; def self.name; 'A'; end }
    [
      [{ x: [:string] }, true],
      [{ x: [serializable_class] }, true],
      [{ x: [Object.new] }, false],
      [{ x: [Class.new] }, false],
      [{ x: [:strange] }, false]
    ].each do |type, ok|
      klass = Class.new { include ArSerializer::Serializable; def self.name; 'B'; end; serializer_field :to_s, type: type }
      test = -> { ArSerializer::TypeScript.generate_type_definition klass }
      if ok
        test.call
      else
        assert_raises(ArSerializer::GraphQL::TypeClass::InvalidType, &test)
      end
    end
  end

  def test_non_activerecord
    output = ArSerializer.serialize User.all, { favorite_post: { post: :id } }
    assert(output.any? { |user| user[:favorite_post] && user[:favorite_post][:post][:id] })
  end

  def test_defaults
    klass = Class.new do
      include ArSerializer::Serializable
      serializer_field(:id) { 1 }
      serializer_field(:name) { 'name' }
      serializer_defaults(namespace: :foo) { { bar: 2, baz: 3 } }
    end
    obj = klass.new
    assert_equal ArSerializer.serialize(obj, :id), { id: 1 }
    assert_equal ArSerializer.serialize(obj, :id, use: :foo), { id: 1, bar: 2, baz: 3 }
    assert_equal ArSerializer.serialize(obj, :*, use: :foo), { id: 1, name: 'name', bar: 2, baz: 3 }
  end

  def test_schema
    schema = Class.new do
      def self.name
        'TestSchema'
      end
      include ArSerializer::Serializable
      serializer_field :user, type: User do |_context, id:|
        User.find id
      end
      serializer_field :users, type: [User], params_type: { words: [:string] } do
        User.all
      end
      serializer_field :__schema do
        ArSerializer::GraphQL::SchemaClass.new self.class
      end
    end
    query = %(
       {
         user(id: 3) {
           name
           PS: posts {
             id
             title
           }
         }
         users {
           id
           name
         }
       }
    )
    default_schema = ArSerializer::GraphQL.definition schema
    aaa_schema = ArSerializer::GraphQL.definition schema, use: :aaa
    bbb_schema = ArSerializer::GraphQL.definition schema, use: :bbb
    assert default_schema != aaa_schema
    assert default_schema != bbb_schema
    assert aaa_schema != bbb_schema
    result = ArSerializer::GraphQL.serialize(schema.new, query).as_json
    assert result['data']['user']['PS']
    graphiql_query_path = File.join File.dirname(__FILE__), 'graphiql_query'
    assert ArSerializer::GraphQL.serialize(schema.new, File.read(graphiql_query_path)).as_json
    assert ArSerializer::TypeScript.generate_type_definition(schema)
  end

  def test_graphql_query_parse
    random_json = lambda do |level|
      chars = %("\\{[]},0a).chars
      if level <= 0
        [
          Array.new(10) { chars.sample }.join,
          rand(10),
          true,
          false
        ].sample
      elsif rand < 0.5
        Array.new(4) { random_json.call rand(level) }
      else
        Array.new 4 do
          [Array.new(4) { chars.sample }.join, random_json.call(rand(level))]
        end.to_h
        Array.new 4 do
          [Array.new(4) { chars.sample }.join, 'aaa']
        end
      end
    end
    query = %(
      # comment
      {
        user(aa: #{random_json.call(4).to_json}) {
          foo() # comment
          bar(aa: #{random_json.call(4).to_json}, bb: #{random_json.call(4).to_json})
        }
      },
      query Xyz($n: [[Int!]!]!) {
        ...Frag
      }
      fragment Frag on FooBar {
        aa(id: $n)
        bb, cc
      }
    )
    ArSerializer::GraphQL::Parser.parse query, operation_name: 'Xyz', variables: { 'n' => 1 }
  end
end
