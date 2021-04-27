# frozen_string_literal: true

# kenna-external-vulns
require 'rest-client'
require 'json'
require 'csv'

@token = ARGV[0]
@data_file = ARGV[1]
@custom_field_meta = ARGV[2] # csv of column names in data and what custom field to put them in
@primary_locator = ARGV[3] # hostname or ip_address or url or application
@locator_column = ARGV[4] # column in csv that has primary locator info (actual ip, hostname or url)
@vuln_type = ARGV[5] # cve or cwe or wasc
@vuln_column = ARGV[6] # column that holds the vuln data
@notes_meta = ARGV[7] # prefix and column names to be included in notes
@hostcase = ARGV[8] # upcase, downcase or nochange
@last_seen_column = ARGV[9]
@first_found_column = ARGV[10]
@due_date_column = ARGV[11]
@status = ARGV[12]
@identifier = ARGV[13]

@vuln_api_url = 'https://api.kennasecurity.com/vulnerabilities'
@search_url = '/search?q='
@headers = { 'content-type' => 'application/json', 'X-Risk-Token' => @token, 'accept' => 'application/json' }
@max_retries = 5
@debug = false

# Encoding characters
enc_colon = '%3A'
enc_dblquote = '%22'
enc_space = '%20'

## Query API with query_url
asset_id = nil
key = nil
vuln_id = nil
status = nil
serviceName = nil
@custom_fields = []
@notes_fields = []

start_time = Time.now
output_filename = "kenna-external-vulns_log-#{start_time.strftime('%Y%m%dT%H%M')}.txt"

def build_ip_url(ipstring)
  puts 'building ip url' if @debug
  url = ''
  if ipstring.index('/').nil?
    subnet = IPAddr.new(ipstring)
    url = "ip:#{@enc_dblquote}#{subnet}#{@enc_dblquote}"
  else
    subnet = IPAddr.new(ipstring)
    iprange = subnet.to_range
    beginip = iprange.begin
    endip = iprange.end
    url = "ip:[#{beginip} TO #{endip}]"
  end
  url
end

def build_hostname_url(hostname)
  puts 'building hostname url' if @debug
  case @hostcase
  when 'upcase'
    hostname.upcase!
  when 'downcase'
    hostname.downcase!
  end
  "hostname:#{@enc_dblquote}#{hostname}*#{@enc_dblquote}"
end

def is_ip?(str)
  !IPAddr.new(str).nil?
rescue StandardError
  false
end

def cleanVulnData(vulnData)
  finalvulns = []
  puts "before #{vulnData}"
  if !vulnData.nil? && @vuln_type == 'cve'
    vulnData = vulnData.gsub(/\(.*?\)/, '')
    puts "removed paren #{vulnData}"
    vulnData = vulnData.gsub(/\s+/, '')
    temp_vulns = vulnData.split(',')
    temp_vulns.each do |value|
      finalvulns << value.sub(/\ACVE-/, '')[0..8]
    end
  end
  puts "size #{finalvulns.size}"
  finalvulns
end

unless @custom_field_meta.empty?
  CSV.foreach(@custom_field_meta, headers: true, encoding: 'UTF-8') do |row|
    @custom_fields << Array[row[0], row[1]]
  end
end
unless @notes_meta.empty?
  CSV.foreach(@notes_meta, headers: true, encoding: 'UTF-8') do |row|
    @notes_fields << Array[row[0], row[1]]
  end
end

CSV.foreach(@data_file, headers: true, encoding: 'UTF-8') do |row|
  locator = row[@locator_column.to_s]

  notes = ''
  custom_field_string = ''
  query_url = ''
  temp_uri = ''
  status = row[@status.to_s]
  identifier = row[@identifier.to_s]
  api_query = nil

  unless row[@locator_column.to_s].nil?
    case @primary_locator
    when 'ip_address'
      api_query = build_ip_url(row[@locator_column.to_s])
    when 'hostname'
      api_query = build_hostname_url(row[@locator_column.to_s])
    when 'url'
      locator = "http://#{locator}" unless locator.start_with?('http')
      api_query = "url:#{enc_dblquote}#{locator}#{enc_dblquote}"
    when 'application'
      api_query = "application:#{enc_dblquote}#{locator}#{enc_dblquote}"
    end
  end
  vuln_array = []
  unless @vuln_type.nil?
    temp_vuln_array = cleanVulnData(row[@vuln_column])
    temp_vuln_array.each do |value|
      vuln_array << if @vuln_type == 'vuln_id'
                      "id%5B%5D=#{value}"
                    else
                      "#{@vuln_type}:#{value}"
                    end
    end
  end
  queries = []
  if vuln_array.any?
    vuln_array.each do |vuln_item|
      query_url = if @vuln_type == 'vuln_id'
                    "#{@vuln_api_url}#{@search_url}#{query_url}#{vuln_item}"
                  else
                    "#{@vuln_api_url}#{@search_url}#{@urlquerybit}#{vuln_item}"
                  end
      query_url = query_url.gsub(/&$/, '')
      query_url = "#{query_url}+AND+#{api_query}" unless api_query.nil?
      queries << [query_url, vuln_item]
    end
  else
    query_url = "#{@vuln_api_url}#{@search_url}#{@urlquerybit}"
    query_url = query_url.gsub(/&$/, '')
    queries << query_url
  end

  puts "query url = #{queries[0]}"

  last_seen = if !@last_seen_column.nil? && !@last_seen_column == ''
                DateTime.parse(row[@last_seen_column.to_s]).strftime('%FT%TZ')
              else
                Time.now.strftime('%FT%TZ')
              end

  @notes_fields.each do |item|
    row_value = row[item[0]]
    unless row_value.nil?
      row_value = row_value.gsub(/['<','>','_','\n','\t','\r',':','(',')',''',"{","}"]/, '').chomp
      notes << "#{item[1]}#{row_value}"
    end
  end

  @custom_fields.each do |item|
    row_value = row[item[0]]
    unless row_value.nil?
      row_value = row_value.gsub(/['<','>','_','\n','\t','\r',':','(',')',''',"{","}"]/, '').chomp
      custom_field_string << "\"#{item[1]}\":\"#{row_value}\","
    end
  end

  custom_field_string = custom_field_string[0...-1]

  queries.each do |query|
    find_vuln_query = query[0]
    vuln_cve = query[1]

    begin
      vuln_id = nil

      get_response = RestClient::Request.execute(
        method: :get,
        url: find_vuln_query,
        headers: @headers
      )
      get_response_json = JSON.parse(get_response)['vulnerabilities']
      get_response_json.each do |item|
        vuln_id = item['id']
      end
      puts "vuln_id= #{vuln_id}" if @debug

      # vuln_column_data = row[@vuln_column][0..12]
      vuln_create_json_string = "{\"vulnerability\":{\"#{@vuln_type}_id\":\"#{vuln_cve.sub! 'cve:',
                                                                                            'CVE-'}\",\"primary_locator\":\"#{@primary_locator}\","\
          "\"last_seen_time\":\"#{last_seen}\","

      unless @first_found_column.empty?
        vuln_create_json_string = "#{vuln_create_json_string}\"found_on\":\"#{DateTime.parse(row[@first_found_column]).strftime('%FT%TZ')}\","
      end

      unless @due_date_column.empty?
        vuln_create_json_string = "#{vuln_create_json_string}\"due_date\":\"#{DateTime.parse(row[@due_date_column]).strftime('%FT%TZ')}\","
      end

      vuln_create_json_string = "#{vuln_create_json_string}\"identifier\":\"#{identifier}\"," unless @identifier.empty?

      vuln_create_json_string = "#{vuln_create_json_string}\"#{@primary_locator}\":\"#{locator}\"}}"

      vuln_create_json = JSON.parse(vuln_create_json_string)

      vuln_update_json_string = '{"vulnerability":{'

      vuln_update_json_string = if status.nil? || status.empty?
                                  "#{vuln_update_json_string}\"status\":\"open\""
                                else
                                  "#{vuln_update_json_string}\"status\":\"#{status}\""
                                end
      unless @custom_field_meta.empty?
        vuln_update_json_string = "#{vuln_update_json_string},\"custom_fields\":{#{custom_field_string}}\""
      end
      vuln_update_json_string = "#{vuln_update_json_string},\"notes\":\"#{notes}\"" unless @notes_meta.empty?
      vuln_update_json_string = "#{vuln_update_json_string},\"last_seen_time\":\"#{last_seen}\"}}"
      # vuln_update_json_string = "#{vuln_update_json_string}}}"

      puts vuln_update_json_string if @debug
      vuln_update_json = JSON.parse(vuln_update_json_string)

      puts vuln_create_json
      puts vuln_update_json if @debug

      if vuln_id.nil?
        log_output = File.open(output_filename, 'a+')
        log_output << "Kenna Creating Vuln for new asset. #{row[@vuln_column]} AND #{row[@locator_column]}\n"
        log_output.close
        puts 'creating new vuln' if @debug
        update_response = RestClient::Request.execute(
          method: :post,
          url: @vuln_api_url,
          headers: @headers,
          payload: vuln_create_json
        )

        update_response_json = JSON.parse(update_response)['vulnerability']
        new_json = if !@some_var.class == Hash
                     JSON.parse(update_response_json)
                   else
                     update_response_json
                   end

        vuln_id = new_json.fetch('id')
      end

      vuln_custom_uri = "#{@vuln_api_url}/#{vuln_id}"
      puts vuln_custom_uri if @debug
      log_output = File.open(output_filename, 'a+')
      log_output << "Kenna updating vuln: #{vuln_id} for #{row[@vuln_column]} AND #{row[@locator_column]}\n"
      log_output.close
      puts 'updating vuln' if @debug
      update_response = RestClient::Request.execute(
        method: :put,
        url: vuln_custom_uri,
        headers: @headers,
        payload: vuln_update_json
      )
      puts update_response
      next if update_response.code == 204

    # end
    rescue RestClient::UnprocessableEntity => e
      log_output = File.open(output_filename, 'a+')
      log_output << "UnprocessableEntity: #{e.message}... (time: #{Time.now}, start time: #{start_time})\n"
      log_output.close
      puts "UnprocessableEntity: #{e.message}"
    rescue RestClient::BadRequest => e
      log_output = File.open(output_filename, 'a+')
      log_output << "BadRequest: #{e.message}... (time: #{Time.now}, start time: #{start_time})\n"
      log_output.close
      puts "BadRequest: #{e.message}"
    rescue RestClient::Exception => e
      puts "i hit an exception #{e.message} #{e.backtrace.inspect}"

      @retries ||= 0
      if @retries < @max_retries
        @retries += 1
        sleep(15)
        retry
      else
        log_output = File.open(output_filename, 'a+')
        log_output << "General RestClient error #{e.message}... (time: #{Time.now}, start time: #{start_time})\n"
        log_output.close
        puts "Exception: #{e.message}"
      end
    end
  end
end
