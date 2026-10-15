require "httparty"
require "nokogiri"
require "json"
require "net/http"

# ===== CONFIGURARE =====
FISIER_PRODUSE = "produse.json"                          # lista de produse urmărite
SELECTOR       = ".current-price .product-price-value"   # selectorul implicit (sportvision.ro); alt site → "selector" în produse.json
FISIER_PRET    = "pret.json"
FISIER_ISTORIC = "istoric.json"                          # un preț pe zi pentru fiecare produs
NTFY_TOPIC     = ENV.fetch("NTFY_TOPIC")                 # secret pe GitHub; local: $env:NTFY_TOPIC = "..."

# ===== 1. Descarcă pagina =====
def descarca_pagina(url)
  raspuns = HTTParty.get(
    url,
    # antete ca ale unui browser real, altfel unele site-uri (ex. sportisimo.ro) răspund cu 403
    headers: {
      "User-Agent"                => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
      "Accept"                    => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
      "Accept-Language"           => "ro-RO,ro;q=0.9,en;q=0.8",
      "Sec-Fetch-Mode"            => "navigate",
      "Sec-Fetch-Dest"            => "document",
      "Sec-Fetch-Site"            => "none",
      "Upgrade-Insecure-Requests" => "1"
    },
    timeout: 20
  )
  raise "Eroare HTTP #{raspuns.code}" unless raspuns.code == 200
  raspuns.body
end

# ===== 2. Extrage prețul =====
def extrage_pret(html, selector)
  doc = Nokogiri::HTML(html)

  # Varianta 1: tag-ul ascuns cu prețul curat
  meta = doc.at_css('meta[itemprop="price"]')
  return meta["content"].to_f if meta && meta["content"]

  # Varianta 2: elementul vizibil, ex. "1.299,99 Lei"
  element = doc.at_css(selector)
  raise "Nu am găsit prețul. Verifică selectorul!" if element.nil?

  text = element.text.strip
  puts "Text găsit pe pagină: #{text.inspect}"
  text.gsub(/[^\d,]/, "").tr(",", ".").to_f   # "1.299,99 Lei" -> 1299.99
end

# ===== 3. Citește / salvează prețurile =====
# pret.json: { "preturi": { "Tricou Lakers": 179.99, ... }, "erori": ["..."], "actualizat": "..." }
def citeste_preturi_vechi
  return {} unless File.exist?(FISIER_PRET)
  JSON.parse(File.read(FISIER_PRET))["preturi"] || {}
end

# produsele care nu au putut fi citite la ultima rulare (ca să nu trimitem aceeași eroare în fiecare oră)
def citeste_erori
  return [] unless File.exist?(FISIER_PRET)
  JSON.parse(File.read(FISIER_PRET))["erori"] || []
end

def salveaza_preturi(preturi, erori)
  date = { preturi: preturi, erori: erori, actualizat: Time.now.strftime("%Y-%m-%d %H:%M") }
  File.write(FISIER_PRET, JSON.pretty_generate(date))
end

# istoric.json: { "Tricou Lakers": [ { "data": "2026-10-14", "pret": 179.99 }, ... ], ... }
def citeste_istoric
  return {} unless File.exist?(FISIER_ISTORIC)
  JSON.parse(File.read(FISIER_ISTORIC))
end

def salveaza_istoric(istoric)
  File.write(FISIER_ISTORIC, JSON.pretty_generate(istoric))
end

# ===== 4. Notificare pe telefon =====
def notifica(mesaj, titlu = "Pret schimbat", link = nil)
  antete = { "Title" => titlu, "Tags" => "moneybag" }
  antete["Click"] = link if link   # atingi notificarea și se deschide produsul
  Net::HTTP.post(URI("https://ntfy.sh/#{NTFY_TOPIC}"), mesaj, antete)
end

# "https://www.ritmo.ro/cafe-cult/..." -> "ritmo.ro"
def site(url)
  URI(url).host.sub(/^www\./, "")
end

# { nume => text } -> rânduri grupate pe site, ex. "ritmo.ro:\n  Cafea ...: 62.0 lei"
def grupat_pe_site(randuri, site_de)
  randuri.group_by { |nume, _| site_de[nume] }.map do |s, lista|
    "#{s}:\n" + lista.map { |nume, text| "  #{nume}: #{text}" }.join("\n")
  end.join("\n\n")
end

# ===== PROGRAMUL PRINCIPAL =====
produse = JSON.parse(File.read(FISIER_PRODUSE))
preturi     = citeste_preturi_vechi
erori       = citeste_erori   # produse stricate la rularea trecută
preturi_azi = {}   # doar produsele citite cu succes la rularea asta
site_de     = {}   # nume produs -> site, ex. "Tricou Lakers" -> "sportvision.ro"

produse.each do |produs|
  nume = produs["nume"]
  url  = produs["url"]
  site_de[nume] = site(url)
  eticheta = "#{nume} (#{site_de[nume]})"   # ce apare în notificări

  begin
    pret_nou = extrage_pret(descarca_pagina(url), produs["selector"] || SELECTOR)
    raise "Prețul citit nu e valid (#{pret_nou})" if pret_nou <= 0
  rescue => e
    puts "#{eticheta} | EROARE: #{e.message}"
    unless erori.include?(nume)   # anunțăm doar prima dată când se strică
      notifica("#{eticheta}: bot-ul nu a găsit prețul. Eroare: #{e.message}", "Bot-ul are o problema", url)
      erori << nume
    end
    next   # trecem la următorul produs, prețul vechi rămâne salvat
  end

  pret_vechi = preturi[nume]
  puts "#{eticheta} | Preț vechi: #{pret_vechi.inspect} | Preț nou: #{pret_nou}"

  if erori.delete(nume)   # era stricat, acum merge din nou
    notifica("#{eticheta}: merge din nou. Preț actual: #{pret_nou} lei", "Rezolvat", url)
  end

  if pret_vechi.nil?
    notifica("#{eticheta}: am început să urmăresc produsul. Preț actual: #{pret_nou} lei", "Produs nou", url)
  elsif pret_nou != pret_vechi
    diferenta = (pret_nou - pret_vechi).round(2)
    semn = diferenta > 0 ? "+" : ""
    notifica("#{eticheta}: #{pret_vechi} -> #{pret_nou} lei (#{semn}#{diferenta} lei)", "Pret schimbat", url)
  else
    puts "Prețul nu s-a schimbat."
  end

  preturi[nume] = pret_nou
  preturi_azi[nume] = pret_nou
end

# La 12:17 (cron-job.org pornește bot-ul la minutul 17 al fiecărei ore):
# salvăm prețul zilei în istoric, apoi trimitem raportul zilnic (duminica: rezumatul săptămânal)
if Time.now.hour == 12 && preturi_azi.any?
  istoric = citeste_istoric
  azi = Time.now.strftime("%Y-%m-%d")
  preturi_azi.each do |nume, pret|
    istoric[nume] ||= []
    istoric[nume] << { "data" => azi, "pret" => pret } unless istoric[nume].last&.dig("data") == azi
  end
  salveaza_istoric(istoric)

  if Time.now.sunday?
    randuri = preturi_azi.keys.to_h do |nume|
      ultimele7 = istoric[nume].last(7).map { |x| x["pret"] }
      medie = (ultimele7.sum / ultimele7.size).round(2)
      [nume, "min #{ultimele7.min}, max #{ultimele7.max}, medie #{medie} lei"]
    end
    notifica("Săptămâna asta:\n\n#{grupat_pe_site(randuri, site_de)}", "Rezumat saptamanal")
  else
    randuri = preturi_azi.to_h { |nume, pret| [nume, "#{pret} lei"] }
    notifica("Prețurile de azi:\n\n#{grupat_pe_site(randuri, site_de)}", "Raport zilnic")
  end
end

erori &= produse.map { |p| p["nume"] }   # uităm erorile produselor șterse din produse.json
salveaza_preturi(preturi, erori)
