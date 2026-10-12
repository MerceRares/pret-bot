require "httparty"
require "nokogiri"

URL = "https://www.sportvision.ro/tricou/537721-nike-tricou-los-angeles-lakers"

html = HTTParty.get(URL, headers: {
  "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/129.0 Safari/537.36"
}).body

doc = Nokogiri::HTML(html)
gasite = doc.css(".product-price-value")

puts "Găsite: #{gasite.size}"
gasite.each_with_index do |el, i|
  parinte = el.parent
  puts "#{i}: #{el.text.strip.ljust(10)} | părinte: <#{parinte.name} class=\"#{parinte['class']}\">"
end