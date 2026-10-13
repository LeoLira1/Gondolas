/// Migração aditiva: preserva o contrato (posicao, ordem) dos apps existentes.
/// Legados usam o id persistente; novos racks recebem UUID no aplicativo.
const migracaoRackIdentidade = [
  "UPDATE galpao_racks SET rack_uuid = 'legacy-' || id WHERE rack_uuid IS NULL OR rack_uuid = ''",
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_galpao_rack_uuid ON galpao_racks(rack_uuid)',
  """CREATE TRIGGER IF NOT EXISTS galpao_rack_identidade_insert
  AFTER INSERT ON galpao_racks WHEN NEW.rack_uuid IS NULL OR NEW.rack_uuid = ''
  BEGIN
    UPDATE galpao_racks SET rack_uuid = lower(hex(randomblob(16))) WHERE id = NEW.id;
  END""",
  """CREATE TRIGGER IF NOT EXISTS galpao_rack_identidade_imutavel
  BEFORE UPDATE OF rack_uuid ON galpao_racks
  WHEN OLD.rack_uuid IS NOT NULL AND OLD.rack_uuid != ''
       AND NEW.rack_uuid IS NOT OLD.rack_uuid
  BEGIN
    SELECT RAISE(ABORT, 'rack_uuid e imutavel');
  END""",
];
