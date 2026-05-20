#coding: utf-8

require 'csv'
require 'json'

# String table for multi language
# String table structure is this
# {key=>word,...} for each language
# string data is stored in ../StringTable.csv

class StringTable
	def initialize
		@table = []
		@string_table = 'StringTable.csv'
	end

	def convert
		@table = []
		CSV.foreach(@string_table,encoding:"UTF-8") do |line|
			next if(line.length == 0 or line[0] == nil or line[0][0] == '#')
			line.delete_at(1)
			puts "#{line}" 
			@table << line
		end

		langs = @table[0].size
		string_table = {}
		1.upto langs do |i|
			next if(@table[0][i] == nil or @table[0][i].length == 0)
			keys = {}
			string_table[@table[0][i]] = keys
			@table.each do |word|
				next if(word[0].include?('key-WORD'))
				w = word[i]
				w = '' if(w == '&empty')
				w = word[1] if(w == nil)				
				keys[word[0]] = w
			end
		end
		file = "StringTable.json"
		begin
			File.open(file,'w') do |io|			
				io.puts(JSON.generate(string_table))
			end
		rescue => e	
			puts "Error: #{e}"
		end
	end		
end

st = StringTable.new
st.convert
