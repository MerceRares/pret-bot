require "httparty"
require "nokogiri"
require "json"
require "net/http"

# ===== CONFIGURARE =====
FISIER_PRODUSE = "produse.json"                          # lista de produse urmărite
SELECTOR       = ".current-price .product-price-value"   # selectorul prețului pe sportvision.ro
FISIER_PRET    = "pret.json"
NTFY_TOPIC     = ENV.fetch("NTFY_TOPIC", "rares-preturi")

# ===== 1. Descarcă pagina =====
def descarca_pagina(url)
  raspuns = HTTParty.get(
    url,
    headers: {
      "User-Agent"      => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36",
      "Accept-Language" => "ro-RO,ro;q=0.9"
    },
    timeout: 20
  )
  raise "Eroare HTTP #{raspuns.code}" unless raspuns.code == 200
  raspuns.body
end

# ===== 2. Extrage prețul =====
def extrage_pret(html)
  doc = Nokogiri::HTML(html)

  # Varianta 1: tag-ul ascuns cu prețul curat
  meta = doc.at_css('meta[itemprop="price"]')
  return meta["content"].to_f if meta && meta["content"]

  # Varianta 2: elementul vizibil, ex. "1.299,99 Lei"
  element = doc.at_css(SELECTOR)
  raise "Nu am găsit prețul. Verifică selectorul!" if element.nil?

  text = element.text.strip
  puts "Text găsit pe pagină: #{text.inspect}"
  text.gsub(/[^\d,]/, "").tr(",", ".").to_f   # "1.299,99 Lei" -> 1299.99
end

# ===== 3. Citește / salvează prețurile =====
# pret.json: { "preturi": { "Tricou Lakers": 179.99, ... }, "actualizat": "..." }
def citeste_preturi_vechi
  return {} unless File.exist?(FISIER_PRET)
  JSON.parse(File.read(FISIER_PRET))["preturi"] || {}
end

def salveaza_preturi(preturi)
  date = { preturi: preturi, actualizat: Time.now.strftime("%Y-%m-%d %H:%M") }
  File.write(FISIER_PRET, JSON.pretty_generate(date))
end

# ===== 4. Notificare pe telefon =====
def notifica(mesaj, titlu = "Pret schimbat", link = nil)
  antete = { "Title" => titlu, "Tags" => "moneybag" }
  antete["Click"] = link if link   # atingi notificarea și se deschide produsul
  Net::HTTP.post(URI("https://ntfy.sh/#{NTFY_TOPIC}"), mesaj, antete)
end

# ===== PROGRAMUL PRINCIPAL =====
produse = JSON.parse(File.read(FISIER_PRODUSE))
preturi = citeste_preturi_vechi
raport  = []

produse.each do |produs|
  nume = produs["nume"]
  url  = produs["url"]

  begin
    pret_nou = extrage_pret(descarca_pagina(url))
    raise "Prețul citit nu e valid (#{pret_nou})" if pret_nou <= 0
  rescue => e
    notifica("#{nume}: bot-ul nu a găsit prețul. Eroare: #{e.message}", "Bot-ul are o problema", url)
    next   # trecem la următorul produs, prețul vechi rămâne salvat
  end

  pret_vechi = preturi[nume]
  puts "#{nume} | Preț vechi: #{pret_vechi.inspect} | Preț nou: #{pret_nou}"

  if pret_vechi.nil?
    notifica("#{nume}: am început să urmăresc produsul. Preț actual: #{pret_nou} lei", "Produs nou", url)
  elsif pret_nou != pret_vechi
    diferenta = (pret_nou - pret_vechi).round(2)
    semn = diferenta > 0 ? "+" : ""
    notifica("#{nume}: #{pret_vechi} -> #{pret_nou} lei (#{semn}#{diferenta} lei)", "Pret schimbat", url)
  else
    puts "Prețul nu s-a schimbat."
  end

  preturi[nume] = pret_nou
  raport << "#{nume}: #{pret_nou} lei"
end

# Raport zilnic la 12:17 (cron-job.org pornește bot-ul la minutul 17 al fiecărei ore)
if Time.now.hour == 12 && raport.any?
  notifica("Prețurile de azi:\n#{raport.join("\n")}", "Raport zilnic")
end

salveaza_preturi(preturi)
