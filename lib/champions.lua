--[[----------------------------------------------------------------------
  lib/champions.lua -- a name pool for lib/identity.lua to assign turtles
  from, so each gets a memorable, human-readable identity instead of a
  colliding CC:Tweaked computer ID (only unique *within one world* -- two
  turtles on two different servers sharing one relay can easily both be
  ID 0). League of Legends champions, cleaned to plain alphanumeric
  CamelCase (no spaces/apostrophes/periods) so every name is safe to use
  directly in a relay URL (e.g. /cmd?id=<name>) without needing
  URL-encoding, which relay.py doesn't do.
------------------------------------------------------------------------]]

return {
  "Aatrox", "Ahri", "Akali", "Akshan", "Alistar", "Amumu", "Anivia", "Annie",
  "Aphelios", "Ashe", "AurelionSol", "Aurora", "Azir", "Bard", "BelVeth",
  "Blitzcrank", "Brand", "Braum", "Briar", "Caitlyn", "Camille", "Cassiopeia",
  "ChoGath", "Corki", "Darius", "Diana", "DrMundo", "Draven", "Ekko", "Elise",
  "Evelynn", "Ezreal", "Fiddlesticks", "Fiora", "Fizz", "Galio", "Gangplank",
  "Garen", "Gnar", "Gragas", "Graves", "Gwen", "Hecarim", "Heimerdinger",
  "Hwei", "Illaoi", "Irelia", "Ivern", "Janna", "JarvanIV", "Jax", "Jayce",
  "Jhin", "Jinx", "KSante", "Kaisa", "Kalista", "Karma", "Karthus", "Kassadin",
  "Katarina", "Kayle", "Kayn", "Kennen", "Khazix", "Kindred", "Kled", "KogMaw",
  "Leblanc", "LeeSin", "Leona", "Lillia", "Lissandra", "Lucian", "Lulu", "Lux",
  "Malphite", "Malzahar", "Maokai", "MasterYi", "Milio", "MissFortune",
  "Mordekaiser", "Morgana", "Naafiri", "Nami", "Nasus", "Nautilus", "Neeko",
  "Nidalee", "Nilah", "Nocturne", "Nunu", "Olaf", "Orianna", "Ornn",
  "Pantheon", "Poppy", "Pyke", "Qiyana", "Quinn", "Rakan", "Rammus", "RekSai",
  "Rell", "Renata", "Renekton", "Rengar", "Riven", "Rumble", "Ryze", "Samira",
  "Sejuani", "Senna", "Seraphine", "Sett", "Shaco", "Shen", "Shyvana",
  "Singed", "Sion", "Sivir", "Skarner", "Smolder", "Sona", "Soraka", "Swain",
  "Sylas", "Syndra", "TahmKench", "Taliyah", "Talon", "Taric", "Teemo",
  "Thresh", "Tristana", "Trundle", "Tryndamere", "TwistedFate", "Twitch",
  "Udyr", "Urgot", "Varus", "Vayne", "Veigar", "Velkoz", "Vex", "Vi", "Viego",
  "Viktor", "Vladimir", "Volibear", "Warwick", "Wukong", "Xayah", "Xerath",
  "XinZhao", "Yasuo", "Yone", "Yorick", "Yuumi", "Zac", "Zed", "Zeri",
  "Ziggs", "Zilean", "Zoe", "Zyra",
}
