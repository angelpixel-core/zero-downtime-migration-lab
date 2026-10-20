# frozen_string_literal: true

# zero_downtime_lab.rb
# Ejecutar: ruby zero_downtime_lab.rb [seed|phase1|phase2|phase3|phase4|status|reset]
require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'
  gem 'activerecord', '>= 7.1', '< 8.1'
  gem 'sqlite3', '>= 1.7', '< 3.0'
end

require 'active_record'
require 'logger'

DB_FILE = 'demo_production.sqlite3'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: DB_FILE)
ActiveRecord::Base.logger = Logger.new($stdout)
ActiveRecord::Base.logger.formatter = proc { |_, _, _, msg| "  [SQL] #{msg}\n" }

command = ARGV[0] || 'help'

case command
when 'seed'
  puts "\n==> [INIT] Creando esquema inicial y generando 1.000 registros..."
  ActiveRecord::Schema.define do
    create_table :users, force: true do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.timestamps
    end
  end

  class User < ActiveRecord::Base; end

  users_data = Array.new(1000) do |i|
    now = Time.now
    { name: "Usuario #{i + 1}", email: "user#{i + 1}@example.com", created_at: now, updated_at: now }
  end
  User.insert_all(users_data)
  puts "==> [OK] 1.000 registros insertados con columna ':name'."

when 'phase1'
  puts "\n==> [DEPLOY 1: EXPAND] Agregando nueva columna ':full_name' nullable..."
  if ActiveRecord::Base.connection.column_exists?(:users, :full_name)
    puts "==> [SKIP] La columna ':full_name' ya existe en la base de datos."
  else
    ActiveRecord::Base.connection.add_column :users, :full_name, :string
    puts "==> [OK] Columna ':full_name' agregada sin cerrojos destructivos."
  end

when 'phase2'
  puts "\n==> [DEPLOY 2: DUAL WRITE & BACKFILL VIA ID PLUCK]"

  class User < ActiveRecord::Base
    # 1. Dual writing en el modelo para nuevas escrituras
    before_save :sync_names

    def sync_names
      self.full_name = name if full_name.blank? && name.present?
    end
  end

  # Demostración del Dual-Writing en vivo con un nuevo registro
  new_live_user = User.create!(name: "Usuario En Vivo", email: "live@example.com")
  puts "==> [DUAL WRITE DEMO] Insertado id=#{new_live_user.id} -> name='#{new_live_user.name}', full_name='#{new_live_user.full_name}'"

  # 2. Paso previo: recolectar el array plano de IDs pendientes de backfill
  target_ids = User.where(full_name: nil).pluck(:id)
  puts "==> Total de registros pendientes identificados: #{target_ids.size}"

  # 3. Procesar en bloques controlados usando el array plano
  batch_size = 250
  migrated_count = 0

  target_ids.each_slice(batch_size) do |batch_ids|
    # Update acotado específicamente a los IDs del lote
    User.where(id: batch_ids).update_all('full_name = name')
    migrated_count += batch_ids.size
    print "."
    sleep 0.05 # Simula control de throttled backfill para evitar lag en réplicas
  end

  puts "\n==> [OK] Backfill completado: #{migrated_count} registros actualizados en lotes."

when 'phase3'
  puts "\n==> [DEPLOY 3: READ SWITCH & IGNORE OLD COLUMN]"
  class User < ActiveRecord::Base
    # Rails ignora la columna vieja en el SELECT users.* (evita romper cache de columnas antes del drop)
    self.ignored_columns += %w[name]
  end

  puts "==> Verificando atributos cargados en memoria por ActiveRecord:"
  sample = User.first
  puts "    Atributos visibles en ActiveRecord: #{sample.attributes.keys.inspect}"
  puts "    Leyendo nuevo campo: sample.full_name = '#{sample.full_name}'"
  puts "    ¿Existe campo name en memoria? #{sample.attributes.key?('name') ? 'Sí' : 'No (ignorado con éxito)'}"
  puts "==> [OK] La aplicación ya no referencia ':name'."

when 'phase4'
  puts "\n==> [DEPLOY 4: CONTRACT] Dropeando columna antigua ':name'..."
  if ActiveRecord::Base.connection.column_exists?(:users, :name)
    ActiveRecord::Base.connection.remove_column :users, :name
    puts "==> [OK] Columna ':name' eliminada de la base de datos de forma limpia. Cero downtime."
  else
    puts "==> [INFO] La columna ':name' ya había sido eliminada."
  end

when 'status'
  unless ActiveRecord::Base.connection.table_exists?(:users)
    puts "\n==> [STATUS] La tabla ':users' no existe aún en '#{DB_FILE}'."
    puts "    Ejecuta primero: ruby zero_downtime_lab.rb seed"
    exit
  end

  class User < ActiveRecord::Base; end
  puts "\n==> Estado actual de la base de datos (#{DB_FILE}):"
  puts "    Columnas en DB: #{User.column_names.inspect}"
  puts "    Total de registros: #{User.count}"
  if User.column_names.include?('full_name')
    puts "    Registros con full_name poblado: #{User.where.not(full_name: [nil, '']).count}"
  end
  puts "    Muestra del primer usuario: #{User.first&.attributes.inspect}"

when 'reset'
  if File.exist?(DB_FILE)
    File.delete(DB_FILE)
    puts "\n==> [RESET] Base de datos '#{DB_FILE}' eliminada con éxito."
  else
    puts "\n==> [RESET] No se encontró '#{DB_FILE}' para eliminar."
  end

else
  puts <<~HELP
    === Laboratorio Zero-Downtime Rails (Expand & Contract) ===
    Uso:
      ruby zero_downtime_lab.rb seed     # Inicializa la DB y crea 1.000 usuarios
      ruby zero_downtime_lab.rb phase1   # Deploy 1: Add column nullable (Expand)
      ruby zero_downtime_lab.rb phase2   # Deploy 2: Dual write + Backfill en lotes
      ruby zero_downtime_lab.rb phase3   # Deploy 3: Read switch + ignored_columns
      ruby zero_downtime_lab.rb phase4   # Deploy 4: Remove old column (Contract)
      ruby zero_downtime_lab.rb status   # Inspecciona el esquema y datos actuales
      ruby zero_downtime_lab.rb reset    # Limpia el archivo SQLite local
  HELP
end
