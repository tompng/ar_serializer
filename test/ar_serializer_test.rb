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

  def test_child_nil
    post = Post.first
    post.user = nil
    expected = { user: nil }
    assert_equal expected, ArSerializer.serialize(post, :user)
  end

  def test_children_including_nil
    u1, u2 = User.limit 2
    klass = Class.new do
      include ArSerializer::Serializable
      serializer_field(:userOrNils) { [u1, nil, u2] }
    end
    result = ArSerializer.serialize klass.new, { userOrNils: :id }
    expected = { userOrNils: [{ id: u1.id }, nil, { id: u2.id }] }
    assert_equal expected, result
  end

  def test_serializing_nil
    assert_nil ArSerializer.serialize(nil, :id)
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
    query = { posts: { comments: [:id, params: { first: 1, order_by: :body }] } }
    data = ArSerializer.serialize user, query
    assert_equal expected, data
    data2 = ArSerializer.serialize user, JSON.parse(query.to_json)
    assert_equal data, data2
  end

  def test_order_restriction
    query = {
      posts: [
        :id,
        params: { order_by: :created_at, direction: :desc }
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
      [:name, posts: [:title, params: { direction: :desc }]],
      [:name, posts: [:title, params: { direction: :asc }]]
    ].each do |query|
      assert ArSerializer.serialize(user_class.all, query)
    end
    assert_raises(ArSerializer::InvalidQuery) do
      query = [:name, posts: [:title, params: { order_by: :body }]]
      ArSerializer.serialize user_class.all, query
    end
  end

  def test_params_underscore
    klass = Class.new do
      include ArSerializer::Serializable
      serializer_field(:p) { |**params| params }
      serializer_field(:self) { self }
    end
    query = {
      p: { params: { 'a_b' => { c_d: 2, 'eF' => 3 }, gH: { 'i_j' => 4, kL: 5 } } },
      self: {
        p: { params: { 'a_b_c' => 1, 'ddEeFf' => 2 } }
      }
    }
    result = ArSerializer.serialize klass.new, query
    expected = {
      p: { a_b: { c_d: 2, e_f: 3 }, g_h: { i_j: 4, k_l: 5 } },
      self: {
        p: { a_b_c: 1, dd_ee_ff: 2 }
      }
    }
    assert_equal expected, result
  end

  def test_accept_deprecated_ordering
    ns = __method__
    Comment.serializer_field :updatedAt, namespace: ns
    post_id, _size = Comment.group(:post_id).count.max_by(&:last)
    post = Post.find post_id
    post_query = ->(params) { { comments: { attributes: :id, params: params } } }
    normal_query = ->(mode) { post_query.call({ direction: mode }) }
    deprecated_query1 = ->(mode) { post_query.call({ order: mode }) }
    deprecated_query2 = ->(mode) { post_query.call({ order: { id: mode } }) }
    n_asc = ArSerializer.serialize post, normal_query.call(:asc), use: ns
    n_desc = ArSerializer.serialize post, normal_query.call(:desc), use: ns
    d_asc1 = ArSerializer.serialize post, deprecated_query1.call(:asc), use: ns
    d_desc1 = ArSerializer.serialize post, deprecated_query1.call(:desc), use: ns
    d_asc2 = ArSerializer.serialize post, deprecated_query2.call(:asc), use: ns
    d_desc2 = ArSerializer.serialize post, deprecated_query2.call(:desc), use: ns
    assert n_asc != n_desc
    assert_equal n_asc, d_asc1
    assert_equal n_desc, d_desc1
    assert_equal n_asc, d_asc2
    assert_equal n_desc, d_desc2
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
    assert ArSerializer.serialize(user_class.all, { posts: [:title, :body, params: { order_by: :title }] })
    assert ArSerializer.serialize(user_class.all, { posts: [:title, params: { order_by: :createdAt }] })
    assert ArSerializer.serialize(user_class.all, { postsExceptCreatedAt: [:title, params: { order_by: :title }] })
    assert ArSerializer.serialize(user_class.all, { postsOnlyTitle: [:title, params: { order_by: :title }] })
    assert_raises(ArSerializer::InvalidQuery) do
      ArSerializer.serialize user_class.all, { posts: [:title, :body, params: { order_by: :body }] }
    end
    assert_raises(ArSerializer::InvalidQuery) do
      ArSerializer.serialize user_class.all, { postsExceptCreatedAt: [:title, params: { order_by: :createdAt }] }
    end
    assert_raises(ArSerializer::InvalidQuery) do
      ArSerializer.serialize user_class.all, { postsOnlyTitle: [:title, params: { order_by: :body }] }
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
          { posts: [:id, field, params: { order_by: field }] }
        )[:posts].map { |post| post[:id] }
      end
      user.posts.each do |post|
        post.update column => rand.days.ago
      end
      assert_equal user.posts.order(column => :asc).ids, get_target_ids.call
    end
  end

  def test_order_first_last
    [:asc, :desc].product([:first, :last, :limit]) do |direction, first_last|
      result = ArSerializer.serialize(Post.all, { comments: [:id, params: { order_by: :id, direction: direction, first_last => 2 }] })
      expected = Post.all.map do |post|
        method = first_last == :limit ? :first : first_last
        comments = post.comments.order(id: direction).to_a.__send__(method, 2)
        { comments: comments.map { |c| { id: c.id } } }
      end
      assert_equal expected, result
    end
  end

  def test_camelized_association
    posts = ArSerializer.serialize Post.all, { Comments: :id, comments: :id }
    assert(posts.all? { |post| post[:comments] == post[:Comments] })
  end

  def test_non_array_composite_value
    output = ArSerializer.serialize User.all, { first2posts_with_total: :id }
    output_ref = ArSerializer.serialize User.all, { posts: :id }
    result = output.zip(output_ref).all? do |o, oref|
      posts_with_total = o[:first2posts_with_total]
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
      [{ x: [:strange] }, false],
      [ArSerializer::TSType.new('null | undefined'), true],
      [{ x: ArSerializer::TSType.new('null | undefined') }, true]
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

  def test_child_of_new_records
    klass = Class.new do
      include ArSerializer::Serializable
      def initialize(user); @user = user; end
      serializer_field(:user) { @user }
    end
    users = User.limit(3)
    objects = users.map { |u| klass.new u }
    posts = users.map { |u| Post.new user: u }
    result1 = ArSerializer.serialize objects, { user: :id }
    result2 = ArSerializer.serialize posts, { user: :id }
    expected = users.map { |u| { user: { id: u.id } } }
    assert_equal expected, result1
    assert_equal expected, result2
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
    assert_raises(ArSerializer::InvalidQuery) { ArSerializer.serialize obj, :defaults }
  end

  def test_has_one_permission
    ns = __method__
    User.serializer_permission(namespace: ns) { id.odd? }
    Comment.serializer_field :userId, namespace: ns
    query = { comments: [:userId, :user] }
    result = ArSerializer.serialize Post.all, query, use: ns
    comments = result.flat_map { |p| p[:comments] }
    assert comments.any? { |c| c[:userId].odd? }
    assert comments.any? { |c| c[:userId].even? }
    assert comments.all? { |c| c[:userId].odd? == !!c[:user] }
  end

  def test_has_many_permission
    ns = __method__
    Comment.serializer_permission(namespace: ns) { user_id.odd? }
    query = { posts: { comments: { user: :id } } }
    result = ArSerializer.serialize User.all, query, use: ns
    comments = result.map { |u| u[:posts].map { |p| p[:comments] } }.flatten
    assert comments.all? { |c| c[:user][:id].odd? }
    assert_equal Comment.where('user_id % 2 = 1').count, comments.size
  end

  def test_permission_toggle
    ns = __method__
    User.serializer_permission(namespace: ns) { id.odd? }
    User.serializer_field(:id_even?, private: true, namespace: ns) { id.even? }
    Comment.serializer_permission(namespace: ns) { id.odd? }
    Comment.serializer_field(:id_even?, private: true, namespace: ns) { id.even? }
    Post.serializer_field :evenUser, association: :user, scoped_access: :id_even?, namespace: ns
    Post.serializer_field :allUser, association: :user, scoped_access: false, namespace: ns
    Post.serializer_field :evenComments, association: :comments, scoped_access: :id_even?, namespace: ns
    Post.serializer_field :allComments, association: :comments, scoped_access: false, namespace: ns
    Post.serializer_field :wrongScopeComments, association: :comments, scoped_access: :foobar, namespace: ns
    query = { comments: :id, evenComments: :id, allComments: :id, user: :id, allUser: :id, evenUser: :id }
    posts = ArSerializer.serialize Post.all, query, use: ns
    assert posts.map { |p| p[:user]&.[] :id }.compact.all?(&:odd?)
    assert posts.map { |p| p[:evenUser]&.[] :id }.compact.all?(&:even?)
    all_user_ids = posts.map { |p| p[:allUser][:id] }
    assert all_user_ids.any?(&:odd?)
    assert all_user_ids.any?(&:even?)
    assert posts.flat_map { |p| p[:comments].map { |c| c[:id] } }.all?(&:odd?)
    assert posts.flat_map { |p| p[:evenComments].map { |c| c[:id] } }.all?(&:even?)
    all_comment_ids = posts.flat_map { |p| p[:allComments].map { |c| c[:id] } }
    assert all_comment_ids.any?(&:odd?)
    assert all_comment_ids.any?(&:even?)
    assert_raises(ArgumentError) { ArSerializer.serialize Post.all, :wrongScopeComments, use: ns }
  end

  def test_permission_preloader
    ns = __method__
    p1_count = 0
    p2_count = 0
    p3_count = 0
    preloader1 = ->(users) { p1_count += 1; [:p1, users.size] }
    preloader2 = ->(users) { p2_count += 1; [:p2, users.size] }
    preloader3 = ->(users) { p3_count += 1; [:p3, users.size] }
    commented_users_count = Comment.distinct.count(:user_id)
    User.serializer_permission namespace: ns, preload: [preloader1, preloader2] do |p1, p2|
      raise unless p1 == [:p1, commented_users_count]
      raise unless p2 == [:p2, commented_users_count]
      id.odd?
    end
    User.serializer_field :test, namespace: ns, preload: [preloader2, preloader3] do |p2, p3|
      p2 + p3
    end
    query = { user: [:id, :test] }
    comments = ArSerializer.serialize Comment.all, query, use: ns
    users = comments.map { |c| c[:user] }.compact
    assert users.any?
    assert commented_users_count != users.size
    assert_equal [:p2, commented_users_count, :p3, users.uniq.size], users[0][:test]
    assert_equal [1, 1, 1], [p1_count, p2_count, p3_count]
  end

  def test_field_permission
    ns = __method__
    permission = ->(user, **kw) { self == user }
    User.serializer_field(:email1, permission: permission, namespace: ns) { :email1 }
    User.serializer_field(:email2, permission: permission, fallback: 'no_email', namespace: ns) { :email2 }
    a = { email1: :email1, email2: :email2 }
    b = { email1: nil, email2: 'no_email' }
    query = [:email1, :email2]
    users = [User.first, User.second, User.third]
    users.each { |u| u.posts.create! }
    result1 = ArSerializer.serialize users, query, context: users.third, use: ns
    assert_equal [b, b, a], result1
    result2 = ArSerializer.serialize users.map { |u| u.posts.first }, { user: query }, context: users.second, use: ns
    assert_equal [{ user: b }, { user: a }, { user: b}], result2
  end

  def test_count_field_permission
    ns = __method__
    Comment.serializer_field :a, count_of: :stars, permission: ->(ctx, **kw) { id.odd? }, namespace: ns
    result = ArSerializer.serialize Comment.all, [:id, :stars_count, :a], use: ns
    odds, evens = result.partition { |r| r[:id].odd? }
    assert odds.size >= 1 && odds.all? { |c| c[:a] == c[:stars_count] }
    assert evens.size >= 1 && evens.all? { |c| c[:a] == 0 }
  end

  def test_preloader_set
    ns = __method__
    Comment.serializer_field :a, preload: ->cs { cs.map(&:id).select(&:even?).to_set }, namespace: ns
    result = ArSerializer.serialize Comment.all, [:id, :a], use: ns
    assert result.all? { |c| c[:a] == c[:id].even? }
  end

  def test_preloader_fallback
    ns = __method__
    Comment.serializer_field :a, preload: ->cs { cs.map { |c| [c.id, 'odd'] if c.id.odd? }.compact.to_h }, fallback: 'even', namespace: ns
    result = ArSerializer.serialize Comment.all, [:id, :a], use: ns
    assert ['even', 'odd'], result.map { |c| c[:a] }.uniq.sort
    assert result.all? { |c| c[:a] == c[:id].odd? ? 'odd' : 'even' }
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
      serializer_field :something, ts_type: '{ x: unknown }', ts_params_type: 'Record<string, number>' do
        { x: 1 }
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

  def test_params_default_type
    field = ArSerializer::Field.new(Object, :foo, data_block: ->(ctx, id:, ids:, foo_id:,foo_ids:, bar_id: 0, bar_ids: [], apple:, apples:, book: 0, books: []){})
    expected = ArSerializer::GraphQL::TypeClass.from({
      'id' => :int,
      'ids' => [:int],
      'fooId' => :int,
      'fooIds' => [:int],
      'apple' => :any,
      'apples' => [:any],
      'barId?' => :int,
      'barIds?' => [:int],
      'book?' => :any,
      'books?' => [:any]
    }).ts_type
    assert_equal expected, field.arguments_type.ts_type
  end

  def test_ts_type_generate
    schema = Class.new do
      def self.name; 'Schema'; end
      include ArSerializer::Serializable
      serializer_field :optional1, type: :string, params_type: { optional1?: :int } do end
      serializer_field :optional2, type: :string, params_type: { optional2: [:string, nil] } do end
      serializer_field :nestedfield, type: [{ a: [:int] }, { b: [:number, :string] }], params_type: { x: :int, y: [:string] } do end
      serializer_field :tsfield, type: ArSerializer::TSType.new('A<B>'), params_type: ArSerializer::TSType.new('C<D>') do end
      serializer_field :mixedfield, type: { x: ArSerializer::TSType.new('E<F>'), y: :string }, params_type: { a: :int, b: ArSerializer::TSType.new('G<H>') } do end
    end
    ts = ArSerializer::TypeScript.generate_type_definition schema
    assert_includes ts, 'nestedfield: ({ a: (number []) } | { b: (number | string) })'
    assert_includes ts, 'tsfield: A<B>'
    assert_includes ts, 'mixedfield: { x: E<F>; y: string }'
    assert_includes ts, 'params: { x: number; y: (string []) }'
    assert_includes ts, 'params: C<D>'
    assert_includes ts, 'params: { a: number; b: G<H> }'

    assert_includes ts, 'params?: { optional1?: number }'
    assert_includes ts, 'params?: { optional2: (string | null) }'
  end

  def test_only_except_ts_type
    user_class = Class.new do
      def self.name; 'User'; end
      include ArSerializer::Serializable
      serializer_field :id, type: :int
      serializer_field :name, type: :string
      serializer_field :age, type: :int
      serializer_field :email, type: :string
    end

    schema = Class.new do
      def self.name; 'Schema'; end
      include ArSerializer::Serializable
      serializer_field :user1, type: user_class, only: [:id, :name]
      serializer_field :user2, type: user_class, except: [:name]
      serializer_field :user3, type: [user_class, nil], only: [:name, :age]
      serializer_field :user4, type: [user_class, nil], except: [:age]
      serializer_field :users1, type: [user_class], only: [:age, :email]
      serializer_field :users2, type: [user_class], except: [:email]
    end

    ts = ArSerializer::TypeScript.generate_type_definition schema

    assert_includes ts, 'user1: TypeUserOnlyIdName'
    assert_includes ts, 'user2: TypeUserExceptName'
    assert_includes ts, 'user3: (TypeUserOnlyNameAge | null)'
    assert_includes ts, 'user4: (TypeUserExceptAge | null)'
    assert_includes ts, 'users1: (TypeUserOnlyAgeEmail [])'
    assert_includes ts, 'users2: (TypeUserExceptEmail [])'
    assert_match /TypeUserExceptName \{\s+id: number\s+age: number\s+email: string\s+_meta\?/, ts
    assert_match /TypeUserExceptAge \{\s+id: number\s+name: string\s+email: string\s+_meta\?/, ts
    assert_match /TypeUserExceptEmail \{\s+id: number\s+name: string\s+age: number\s+_meta\?/, ts
    assert_match /TypeUserOnlyIdName \{\s+id: number\s+name: string\s+_meta\?/, ts
    assert_match /TypeUserOnlyNameAge \{\s+name: string\s+age: number\s+_meta\?/, ts
    assert_match /TypeUserOnlyAgeEmail \{\s+age: number\s+email: string\s+_meta\?/, ts
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
