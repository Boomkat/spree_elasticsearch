module Spree
  Product.class_eval do
    include Elasticsearch::Model

    index_name Spree::ElasticsearchSettings.index
    document_type 'spree_product'

    mapping _all: {'index_analyzer' => 'search_analyzer', 'search_analyzer' => 'whitespace_analyzer'} do
      indexes :name, type: 'multi_field' do
        indexes :name,         type: 'string', analyzer: 'search_analyzer', boost: 100
        indexes :autocomplete, type: 'string', analyzer: 'ngram_analyzer', boost: 100
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
      end
      indexes :description, analyzer: 'snowball'
      indexes :price, type: 'double'
      indexes :sku, type: 'string', index: 'not_analyzed'
      indexes :taxon_ids, type: 'string', index: 'not_analyzed'

      indexes :available_on, type: 'date', format: 'dateOptionalTime', include_in_all: false
      indexes :published,    type: 'bool', index: 'not_analyzed', include_in_all: false

      indexes :release_formats, type: 'nested' do
        indexes :id, type: 'integer', index: 'not_analyzed'
        indexes :release_date, type: 'date', format: 'dateOptionalTime', include_in_all: false

        indexes :format, type: 'string', index: 'not_analyzed'
        indexes :uber_format, type: 'string', index: 'not_analyzed'

        indexes :preorderable, type: 'bool', index: 'not_analyzed'
        indexes :in_stock,     type: 'bool', index: 'not_analyzed'
        indexes :published,    type: 'bool', index: 'not_analyzed'
      end

      # artists
      indexes :artists, type: 'multi_field' do
        indexes :artists,      type: 'string', analyzer: 'search_analyzer'
        indexes :autocomplete, type: 'string', analyzer: 'ngram_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
      end
      # genres
      indexes :genres, type: 'multi_field' do
        indexes :genres,       type: 'string', analyzer: 'search_analyzer'
        indexes :autocomplete, type: 'string', analyzer: 'ngram_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
      end
      # label
      indexes :label, type: 'multi_field' do
        indexes :label,        type: 'string', analyzer: 'search_analyzer'
        indexes :autocomplete, type: 'string', analyzer: 'ngram_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
      end
      # supplier
      indexes :supplier, type: 'multi_field' do
        indexes :supplier,     type: 'string', analyzer: 'search_analyzer'
        indexes :autocomplete, type: 'string', analyzer: 'ngram_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
      end

      indexes :created_at, type: 'date', format: 'dateOptionalTime', include_in_all: false
      indexes :deleted_at, type: 'date', format: 'dateOptionalTime', include_in_all: false
    end

    def as_indexed_json(options = {})
      result = as_json({
        methods: [:price, :sku,
                  :artists, :genres, :label, :supplier],
        only: [:available_on, :description, :name, :created_at, :deleted_at],
        include: {
          variants: {
            only: [:sku],
            include: {
              option_values: {
                only: [:name, :presentation]
              }
            }
          }
        }
      })
      result[:taxon_ids] = taxons.map(&:self_and_ancestors).flatten.uniq.map(&:id) unless taxons.empty?
      result[:image_url] = images.first.attachment.url unless images.empty?
      result
    end

    # Inner class used to query elasticsearch. The idea is that the query is dynamically build based on the parameters.
    class Product::ElasticsearchQuery
      include ::Virtus.model

      attribute :price_min, Float
      attribute :price_max, Float
      attribute :query, String
      attribute :taxons, Array
      attribute :browse_mode, Boolean
      attribute :sorting, String

      # When browse_mode is enabled, the taxon filter is placed at top level. This causes the results to be limited, but facetting is done on the complete dataset.
      # When browse_mode is disabled, the taxon filter is placed inside the filtered query. This causes the facets to be limited to the resulting set.

      # Method that creates the actual query based on the current attributes.
      # The idea is to always to use the following schema and fill in the blanks.
      # {
      #   query: {
      #     filtered: {
      #       query: {
      #         query_string: { query: , fields: [] }
      #       }
      #       filter: {
      #         and: [
      #           { terms: { taxons: [] } },
      #           { terms: { properties: [] } }
      #         ]
      #       }
      #     }
      #   }
      #   filter: { range: { price: { lte: , gte: } } },
      #   sort: [],
      #   aggs:
      # }
      def to_hash
        q = { match_all: {} }
        unless query.blank? # nil or empty
          q = { query_string: { query: query, fields: ['name^5','description','sku'], default_operator: 'AND', use_dis_max: true } }
        end
        query = q

        and_filter = []
        # transform:
        # key: [val, val] -> {terms: properties.key: [val, val] }
        #                    {terms: properties.key: [val] }
        @properties.each do |key, val|
          and_filter << { terms: { "properties.#{key}" => val } }
        end

        sorting = case @sorting
        when "name_asc"
          [ {"name.untouched" => { order: "asc" }}, {price: { order: "asc" }}, "_score" ]
        when "name_desc"
          [ {"name.untouched" => { order: "desc" }}, {price: { order: "asc" }}, "_score" ]
        when "price_asc"
          [ {price: { order: "asc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
        when "price_desc"
          [ {price: { order: "desc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
        when "newest"
          [ {trending_score: {order: "desc" }}, "_score" ]
        when "score"
          [ "_score", {"name.untouched" => { order: "asc" }}, {"price" => { order: "asc" }} ]
        when "discount"
          [ {discount_rate: {order: "desc" }}, "_score" ]
        when "recommended"
          [ {popularity_score: {order: "desc" }}, "_score" ]
        else # same as newest
          [ {trending_score: {order: "desc" }}, "_score" ]
        end

        # facets
        aggs = {
          price: { stats: { field: "price" } },
          merchant: { terms: { field: "properties.merchant", size: 0 } },
          brand: { terms: { field: "properties.brand", size: 0 } },
          taxon_ids: { terms: { field: "taxon_ids", size: 0 } }
        }

        # basic skeleton
        result = {
          min_score: 0.1,
          query: { filtered: {} },
          sort: sorting,
          aggs: aggs
        }

        # add query and filters to filtered
        result[:query][:filtered][:query] = query
        # taxon and property filters have an effect on the facets
        and_filter << { terms: { taxon_ids: taxons } } unless taxons.empty?

        # filter by price
        price = {}
        price[:gte] = price_min if !price_min.nil? && price_min > 0
        price[:lte] = price_max if !price_max.nil? && price_max > 0
        and_filter << { range: { price: price } } unless price.empty?

        # only return products that are available
        and_filter << { range: { available_on: { lte: "now" } } }
        and_filter << { missing: { field: :deleted_at } }
        # and have an image
        #and_filter << { exists: { field: :image_url } }
        result[:query][:filtered][:filter] = { and: and_filter } unless and_filter.empty?

        result
      end
    end
  end
end
