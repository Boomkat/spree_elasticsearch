module Spree
  Product.class_eval do
    include Elasticsearch::Model

    index_name Spree::ElasticsearchSettings.index
    document_type 'spree_product'

    mapping _all: {enabled: false} do
      # search, autocomplete, untouched & exact match
      indexes :name, type: 'multi_field' do
        indexes :name,         type: 'string', analyzer: 'search_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
        indexes :lowercase,    type: 'string', analyzer: 'lowercase_analyzer', include_in_all: false
      end
      indexes :description, analyzer: 'snowball'
      indexes :sku, type: 'string', index: 'not_analyzed'
      indexes :taxon_ids, type: 'string', index: 'not_analyzed'

      indexes :available_on, type: 'date', format: 'dateOptionalTime', include_in_all: false
      indexes :published,    type: 'boolean', index: 'not_analyzed', include_in_all: false

      indexes :latest_release_date, type: 'date', format: 'dateOptionalTime', include_in_all: false

      indexes :tracks, type: 'multi_field' do
        indexes :tracks,      type: 'string', analyzer: 'search_analyzer'
        indexes :untouched,   type: 'string', include_in_all: false, index: 'not_analyzed'
        indexes :lowercase,   type: 'string', analyzer: 'lowercase_analyzer', include_in_all: false
      end

      indexes :track_artists, type: 'multi_field' do
        indexes :track_artists, type: 'string', analyzer: 'search_analyzer'
        indexes :untouched,     type: 'string', include_in_all: false, index: 'not_analyzed'
        indexes :lowercase,     type: 'string', analyzer: 'lowercase_analyzer', include_in_all: false
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

        indexes :discount_type, type: 'string', index: 'not_analyzed'
        indexes :discount_rule, type: 'string', index: 'not_analyzed'
        indexes :discount_price, type: 'double'
        indexes :discount_end_date, type: 'date', format: 'dateOptionalTime', include_in_all: false
      end

      # genres
      indexes :genres, type: 'integer', index: 'not_analyzed'
      # artists
      indexes :artists, type: 'multi_field' do
        indexes :artists,      type: 'string', analyzer: 'search_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
        indexes :lowercase,    type: 'string', analyzer: 'lowercase_analyzer', include_in_all: false
      end
      # label
      indexes :label, type: 'multi_field' do
        indexes :label,        type: 'string', analyzer: 'search_analyzer'
        indexes :untouched,    type: 'string', include_in_all: false, index: 'not_analyzed'
        indexes :lowercase,    type: 'string', analyzer: 'lowercase_analyzer', include_in_all: false
      end

      indexes :created_at, type: 'date', format: 'dateOptionalTime', include_in_all: false
      indexes :deleted_at, type: 'date', format: 'dateOptionalTime', include_in_all: false
    end

    def as_indexed_json(options = {})
      result = as_json({
        only: [:available_on, :description, :name, :published, :created_at, :deleted_at],
      })
      result[:artists] = artists.map(&:name)
      result[:genres] = release.genres.map(&:id)
      result[:label] = label.try(:name)
      result[:sku] = variants.map{|v|  v.definitive_release_format.try(:catalogue_number) }.compact.uniq

      result[:latest_release_date] = release.release_formats(true).maximum(:release_date)
      # Store names of all tracks, uniq'd to be able to search by track name
      result[:tracks] = track_products.map(&:name).uniq
      result[:track_artists] = release.tracks.map {|t| t.artists.map(&:name) }.flatten.uniq

      # map variant data
      result[:variants] = variants.map do |v|
        h = v.as_json({
          only: [:id],
          methods: [:price, :format, :uber_format, :release_date]
        })
        rf = v.definitive_release_format
        h[:sku] = rf.try(:catalogue_number)
        h[:can_preorder] = rf.try(:can_pre_order) || false
        h[:published] = v.published?
        h[:in_stock] = v.suppliable?

        h[:discount_reason]   = rf.try(:discount_reason)
        h[:discount_rule]     = rf.try(:discount_rule)
        h[:discount_price]    = rf.try(:discount_price)
        h[:discount_end_date] = rf.try(:discount_end_date)
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
      attribute :category, String
      attribute :sorting, String
      attribute :product_reviews, Boolean, default: false
      attribute :track_titles, Boolean, default: false

      attribute :raw, Array # for passing ES queries

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
      # }
      def to_hash
        q = { match_all: {} }

        fields, exact_fields = case category
        when 'artist'
          [
            ['artists^3', 'track_artists'],
            ['artists.lowercase^3', 'track_artists.lowercase']
          ]
        when 'release-title'
          [['name^3'], ['name.lowercase^3']]
        when 'label'
          [['label'], ['label.lowercase^1']]
        when 'catalogue-number'
          [['sku'], ['sku']]
        else
          [
            ['artists^5', 'name^3', 'label^1', 'track_artists', 'sku'],
            ['artists.lowercase^5', 'name.lowercase^3', 'label.lowercase^1', 'track_artists.lowercase']
          ]
          # TODO: re-enable description search
        end

        if product_reviews
          fields.push 'description'
        end
        if track_titles
          fields.push 'tracks'
          exact_fields.push 'tracks.lowercase'
        end

        unless query.blank? # nil or empty
          q = {
            bool: {
              should: [
                { multi_match: { query: query, fields: fields, operator: 'and', type: 'best_fields' } },
                { multi_match: { query: query, fields: exact_fields, boost: 1, type: 'best_fields'} }
              ]
            }
          }
        end
        query = q

        and_filter = []

        # taxon and property filters have an effect on the facets
        and_filter << { terms: { taxon_ids: taxons } } unless taxons.empty?

        # append our raw queries (note, this is toplevel, not nested)
        and_filter.concat raw unless raw.blank?

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
            nested << {
              and: [
                { term: { 'variants.discount_reason': 'sale' } },
                { range: { 'variants.discount_end_date': { gte: 'now+1d/d' } } } # "the current time plus one day, rounded down to the nearest day" - tomorrow
              ]
            }
          end
          if status.include?('recommended')
            and_filter << { term: { taxon_ids: BoomkatTaxon.recommended.id } }
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

        sorting = case @sorting
        when "name_asc"
          [ {"name.untouched" => { order: "asc" }}, {price: { order: "asc" }}, "_score" ]
        when "name_desc"
          [ {"name.untouched" => { order: "desc" }}, {price: { order: "asc" }}, "_score" ]
        when "price_asc"
          [ {price: { order: "asc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
        when "price_desc"
          [ {price: { order: "desc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
        when "preorders"
          [ {"variants.release_date": {
            mode: :min,
            order: :asc,
            nested_filter: { and: nested }
          }}, "_id" ]
        when "oldest"
          [ {"variants.release_date": {
            mode: :max,
            order: :asc,
            nested_filter: { and: nested }
          }}, { description: :desc }, "_id" ]
        when "newest"
          [ {"variants.release_date": {
            mode: :max,
            order: :desc,
            nested_filter: { and: nested }
          }}, { description: :desc }, "_id" ]
        else
          [ {"variants.in_stock": {
            mode: :max,
            order: :desc,
            nested_filter: { and: nested }
          }}, "_score" ]
        end

        # basic skeleton
        result = {
          min_score: 0.1,
          query: nil,
          sort: sorting
        }
        # add query and filters to filtered
        filtered = { filtered: { query: query } }
        filtered[:filtered][:filter] = { and: and_filter } unless and_filter.empty?

        # if we're sorting by score, add weighing by release date (newer
        # releases show up higher)
        if sorting.include? "_score"
          result[:query] = {
            function_score: {
              query: filtered,
              functions: [
                { boost_factor: 1 },
                { gauss: {
                  "latest_release_date": {
                    scale: '365d'
                  }
                }
                }
              ],
              boost_mode: :multiply,
              score_mode: :sum
            }
          }
        else # else just filter them
          result[:query] = filtered
        end

        puts result.to_json
        result
      end
    end
  end
end
