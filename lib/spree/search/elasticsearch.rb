module Spree
  module Search
    # The following search options are available.
    #   * taxon
    #   * keywords in name or description
    #   * properties values
    class Elasticsearch <  Spree::Core::Search::Base
      include ::Virtus.model

      attribute :query, String
      attribute :taxons, Array
      attribute :genres, Array
      attribute :status, Array
      attribute :uber_format, Array
      attribute :release_date, String
      attribute :category, String
      attribute :per_page, String
      attribute :page, String
      attribute :sorting, String
      attribute :product_reviews, Boolean
      attribute :track_titles, Boolean

      def initialize(params)
        self.current_currency = Spree::Config[:currency]
        prepare(params)
      end

      def retrieve_products
        search_result = Spree::Product.__elasticsearch__.search(
          Spree::Product::ElasticsearchQuery.new(
            query: query,
            taxons: taxons,
            genres: genres,
            uber_format: uber_format,
            release_date: release_date,
            category: category,
            status: status,
            sorting: sorting,
            product_reviews: product_reviews,
            track_titles: track_titles
          ).to_hash
        )
        @result = search_result.limit(per_page).page(page)
        @result.records
      end

      def facets
        @result.response.aggregations
      end

      module Escaping
        LUCENE_SPECIAL_CHARACTERS = Regexp.new("(" + %w[
          + - && || ! ( ) { } [ ] ^ " ~ * ? \\ /
        ].map { |s| Regexp.escape(s) }.join("|") + ")")

        LUCENE_BOOLEANS = /\b(AND|OR|NOT)\b/

        def self.escape(s)
          # 6 slashes =>
          #  ruby reads it as 3 backslashes =>
          #    the first 2 =>
          #      go into the regex engine which reads it as a single literal backslash
          #    the last one combined with the "1" to insert the first match group
          special_chars_escaped = s.gsub(LUCENE_SPECIAL_CHARACTERS, '\\\\\1').gsub('&', ' ')

          # Map something like 'fish AND chips' to 'fish "AND" chips', to avoid
          # Lucene trying to parse it as a query conjunction
          special_chars_escaped.gsub(LUCENE_BOOLEANS, '"\1"')
        end
      end

      protected

      # converts params to instance variables
      def prepare(params)
        @query = Escaping.escape(params[:keywords] || "")
        @sorting = params[:sorting]
        @category = params[:category].presence
        @taxons = params[:taxon] ? params[:taxon].split(",") : []
        @genres = params[:genre] ? params[:genre].split(",") : []
        @status = params[:status] ? params[:status].split(",") : []
        @uber_format = params[:format].split(",") unless params[:format].nil?
        @release_date = params[:release_date] unless params[:release_date].blank?
        @product_reviews = params[:product_reviews].present?
        @track_titles = params[:track_titles].present?

        @per_page = (params[:per_page].to_i <= 0) ? 25 : params[:per_page].to_i
        @page = (params[:page].to_i <= 0) ? 1 : params[:page].to_i
      end
    end
  end
end
