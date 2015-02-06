require 'nokogiri'
require 'elasticsearch'
require 'pathname'
require 'uri'
require 'logger'
require 'json'
require 'time'
require 'pry'

require 'hdo-transcript-indexer/converter'

Faraday.default_adapter = :patron
Faraday.default_connection_options.request.timeout = 30 # we sometimes see hangs in the API
Faraday.default_connection_options.headers = {'User-Agent' => 'hdo-transcript-downloader | https://www.holderdeord.no/'}

module Hdo
  module Transcript
    class Indexer
      def initialize(options)
        @data_dir     = data_dir_from(options)
        @sessions     = options.fetch(:sessions)
        @faraday      = Faraday.new('http://data.stortinget.no')
        @logger       = Logger.new(STDOUT)
        @create_index = options.fetch(:create_index)
        @index_name   = options.fetch(:index_name)
        @force        = options.fetch(:force)

        @es = Elasticsearch::Client.new(
          log: false,
          url: options.fetch(:elasticsearch_url)
        )
      end

      def execute
        download
        convert
        create_index
        index_docs
      end

      private

      def download
        @sessions.each { |s| fetch_session s }
      end

      def convert
        Pathname.glob(@data_dir.join('s*.xml')).each { |input| convert_to_json(input) }
      end

      def index_docs
        Pathname.glob(@data_dir.join('s*.json')).each { |input| index_file(input) }
      end

      def data_dir_from(options)
        dir = Pathname.new(options.fetch(:data_dir))
        dir.mkpath unless dir.exist?

        dir
      end

      def fetch_session(session)
        res = @faraday.get "http://data.stortinget.no/eksport/publikasjoner?publikasjontype=referat&sesjonid=#{URI.escape session}&format=json"
        data = JSON.parse(res.body)

        data.fetch('publikasjoner_liste').each { |t| fetch_transcript t }
      end

      def fetch_transcript(t)
        id   = t['id']
        dest = @data_dir.join("#{id}.xml")

        if dest.exist? && !@force
          @logger.info "download cached: #{dest}"
        else
          @logger.info "fetching transcript: #{id} => #{dest}"

          res = @faraday.get("http://data.stortinget.no/eksport/publikasjon?publikasjonid=#{id}")
          dest.open('w') { |io| io << res.body }
        end
      end

      def convert_to_json(input_file)
        dest = Pathname.new(input_file.to_s.sub(input_file.extname, '.json'))

        if dest.exist? && !@force
          @logger.info "conversion cached: #{dest}"
        else
          @logger.info "converting: #{input_file} => #{dest}"
          dest.open('w') { |io| io << Converter.parse(input_file.to_s).to_json }
        end
      end

      def index_file(file)
        transcript_id = file.basename.to_s.sub(file.extname, '')
        data          = JSON.parse(file.read)

        data['sections'].each_with_index do |section, idx|
          id = "#{transcript_id}-#{idx}"

          doc = {
            'time'       => data['date'],
            'presidents' => data['presidents']
          }.merge(section)

          res = @es.index index: @index_name, type: 'speech', id: id, body: doc

          @logger.info "#{id}: #{res.inspect}"
        end
      end

      def create_index
        return unless @create_index

        @logger.info "recreating index #{@index_name}"

        @es.indices.delete(index: @index_name) if @es.indices.exists(index: @index_name)
        @es.indices.create index: @index_name, body: { settings: ES_SETTINGS, mappings: ES_MAPPINGS }
      end

      ES_SETTINGS = {
        index: {
          analysis: {
            analyzer: {
              analyzer_shingle: {
                tokenizer: "standard",
                filter: ["standard", "lowercase", "filter_stop", "filter_shingle"]
              }
            },
            filter: {
              filter_shingle: {
                type: "shingle",
                max_shingle_size: 5,
                min_shignle_size: 2,
                output_unigrams: true
              },
              filter_stop: {
                type: "stop",
                stopwords: "_norwegian_"
                # enable_position_increments: false
              }
            }
          }
        }
      }

      ES_MAPPINGS = {
        speech: {
          properties: {
            time: {
              type: 'date',
              format: 'date_time_no_millis'
            },
            text: {
              search_analyzer: 'analyzer_shingle',
              index_analyzer: 'analyzer_shingle',
              type: 'string'
            },
            name: { type: 'string', index: 'not_analyzed' },
            party: { type: 'string', index: 'not_analyzed' },
            presidents: { type: 'string', index: 'not_analyzed' },
            title: { type: 'string', index: 'not_analyzed' }
          }
        }
      }

    end
  end
end

