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
      indexes :sku, type: 'string', index: 'not_analyzed'
      indexes :taxon_ids, type: 'string', index: 'not_analyzed'

      indexes :available_on, type: 'date', format: 'dateOptionalTime', include_in_all: false
      indexes :published,    type: 'boolean', index: 'not_analyzed', include_in_all: false

      indexes :tracks, type: 'multi_field' do
        indexes :tracks,      type: 'string', analyzer: 'search_analyzer'
        indexes :untouched,   type: 'string', include_in_all: false, index: 'not_analyzed'
      end

      indexes :track_artists, type: 'multi_field' do
        indexes :track_artists, type: 'string', analyzer: 'search_analyzer'
        indexes :untouched,     type: 'string', include_in_all: false, index: 'not_analyzed'
      end

      indexes :variants, type: 'nested' do
        indexes :id, type: 'integer', index: 'not_analyzed'
        indexes :sku, type: 'string', index: 'not_analyzed'
        indexes :price, type: 'double'
        indexes :release_date, type: 'date', format: 'dateOptionalTime', include_in_all: false

        indexes :format, type: 'string', index: 'not_analyzed'
        indexes :uber_format, type: 'string', index: 'not_analyzed'

        indexes :can_preorder, type: 'boolean', index: 'not_analyzed'
        indexes :in_stock,     type: 'boolean', index: 'not_analyzed'
        indexes :published,    type: 'boolean', index: 'not_analyzed'
      end

      # genres
      indexes :genres, type: 'integer', index: 'not_analyzed'
      # artists
      indexes :artists, type: 'multi_field' do
        indexes :artists,      type: 'string', analyzer: 'search_analyzer'
        indexes :autocomplete, type: 'string', analyzer: 'ngram_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
      end
      # label
      indexes :label, type: 'multi_field' do
        indexes :label,        type: 'string', analyzer: 'search_analyzer'
        indexes :autocomplete, type: 'string', analyzer: 'ngram_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
      end

      indexes :created_at, type: 'date', format: 'dateOptionalTime', include_in_all: false
      indexes :deleted_at, type: 'date', format: 'dateOptionalTime', include_in_all: false
    end

    def as_indexed_json(options = {})
      result = as_json({
        methods: [:sku],
        only: [:available_on, :description, :name, :published, :created_at, :deleted_at],
      })
      result[:artists] = artists.map(&:name)
      result[:genres] = release.genres.map(&:id)
      result[:label] = label.try(:name) 

      # Store names of all tracks, uniq'd to be able to search by track name
      result[:tracks] = track_products.map(&:name).uniq
      result[:track_artists] = release.tracks.map {|t| t.artists.map(&:name) }.flatten.uniq
  
      # map variant data
      result[:variants] = variants.map do |v|
        h = v.as_json({
          only: [:sku, :id],
          methods: [:price, :format, :uber_format, :release_date]
        })
        h[:can_preorder] = v.definitive_release_format.try(:can_pre_order) || false
        h[:published] = v.published?
        h[:in_stock] = v.in_stock?
        h
      end

      result[:taxon_ids] = taxons.map(&:id).uniq unless taxons.empty?
      result
    end

    # Inner class used to query elasticsearch. The idea is that the query is dynamically build based on the parameters.
    class Product::ElasticsearchQuery
      include ::Virtus.model

      attribute :query, String
      attribute :taxons, Array
      attribute :genres, Array
      attribute :uber_format, Array
      attribute :status, Array
      attribute :release_date, String
      attribute :sorting, String

      def sorting
        case @sorting
        when "name_asc"
          [ {"name.untouched" => { order: "asc" }}, {price: { order: "asc" }}, "_score" ]
        when "name_desc"
          [ {"name.untouched" => { order: "desc" }}, {price: { order: "asc" }}, "_score" ]
        when "price_asc"
          [ {price: { order: "asc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
        when "price_desc"
          [ {price: { order: "desc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
        when "newest"
          [ {release_date: {order: "desc" }}, "_score" ]
        else # same as newest
          [ {release_date: {order: "desc" }}, "_score" ]
        end
      end

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
          q = { query_string: { query: query, fields: ['artists^5', 'name^3', 'label', 'description', 'tracks', 'track_artists', 'sku'], default_operator: 'AND', use_dis_max: true } }
        end
        query = q

        and_filter = []
        # transform:
        # key: [val, val] -> {terms: properties.key: [val, val] }
        #                    {terms: properties.key: [val] }
        #@properties.each do |key, val|
        #  and_filter << { terms: { "properties.#{key}" => val } }
        #end

        # facets
        aggs = {
          artist:    { terms: { field: "artists", size: 0 } },
          genre:     { terms: { field: "genres", size: 0 } },
          label:     { terms: { field: "label", size: 0 } },
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

        # match uber_format
        release_format_filter = {
          nested: {
            path: 'variants',
            filter: {
              and: [ 
                { term: { 'variants.published': true } }
              ]
            }
          }
        }
        nested = release_format_filter[:nested][:filter][:and]

        unless uber_format.empty? || uber_format.include?('all')
          # miscellaneous is a bit messy, it's actually a range of taxons
          if uber_format.include? 'Merchandise'
            uber_format.push("Toys", "Miscellaneous", "Books / Mags", "DVD", "Apparel", "Tickets")
          end
          nested << { terms: { 'variants.uber_format': uber_format } }
        end

        # filter by status (limiting by uber format previously if needed
        unless status.empty? || status.include?('all')
          # filter by stock status
          # both filters enabled == show all
          unless status.include?('in-stock') && status.include?('out-of-stock')
            if status.include?('in-stock')
              nested << { term: { 'variants.in_stock': true } }
            end
            if status.include?('out-of-stock')
              nested << { term: { 'variants.in_stock': false } }
            end
          end

          if status.include?('sale') # items in the sale taxon
            and_filter << { term: { taxon_ids: BoomkatTaxon.sale.id } }
          end

          if status.include?('pre-order') # show preorders
            nested << {
              and: [
                { term: { 'variants.can_preorder': true } },
                { range: { 'variants.release_date': { gte: 'now' } } }
              ]
            }
          else # hide preorders
            nested << { range: { 'variants.release_date': { lte: 'now' } } }
          end
        end

        # filter by release date
        release_date_filter = case release_date
        when 'last-week'
          'now-1w'
        when 'last-month'
          'now-1M'
        when 'last-year'
          'now-1y' 
        else
        end
        nested << { range: { 'variants.release_date': { gte: release_date_filter } } } if release_date_filter
        
        # append the nested query
        and_filter << release_format_filter unless nested.empty?

        # match genres
        and_filter << { terms: { genres: genres } } unless genres.empty? || genres.include?('all')

        # only return products that are available
        and_filter << { range: { available_on: { lte: "now" } } }
        and_filter << { missing: { field: :deleted_at } }
        and_filter << { term: { published: true } }

        result[:query][:filtered][:filter] = { and: and_filter } unless and_filter.empty?
        
        pp result
        result
      end
    end
  end
end
