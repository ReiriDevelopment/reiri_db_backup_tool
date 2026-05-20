#coding: utf-8

require 'csv'
require 'json'

# C <-> F conversion table
# convert CSV file to json
# CSV: C,F
# json: {'toF'=>{'C'=>F,...}, 'toC'=>{'F'=>C,...}}

class TempConversion
	def initialize
		@table = []
		@csv_file = 'TempConversionTable.csv'
	end

	def convert
		@table = []
		CSV.foreach(@csv_file,encoding:"BOM|UTF-8") do |line|
			puts "#{line}"
			next if(line.length == 0 or line[0] == nil or line[0][0] == '#')
			line[0] = line[0].to_f
			line[1] = line[1].to_f
			@table << line
		end
#		puts "#{@table}"

		conv_table = {'toF'=>{},'toC'=>{}}
		file = "tempConversion.json"
		begin
			@table.each do |data|
				conv_table['toF'][data[0]] = data[1]
				conv_table['toC'][data[1]] = data[0] if(data[2] != nil)
			end
			puts "#{conv_table}"
			File.open(file,'w') do |io|			
				io.puts(JSON.generate(conv_table))
			end
		rescue => e	
			puts "Error: #{e}"
		end
	end		
end

st = TempConversion.new
st.convert
