-- STOCKAR 1.6 — esquema multiempresa (referência do que está no Supabase em produção)
-- Projeto: ijsvaqsgqgzxyeqxihrx. Este arquivo documenta o estado final após a troca;
-- as funções (corpo completo) vivem no banco: veja `select pg_get_functiondef(oid)`.

-- Empresas e perfis (login por Supabase Auth: e-mail + senha)
-- companies(id uuid pk, name, logo_url, active, created_at, dashboard_token)
-- profiles(user_id uuid pk -> auth.users, company_id -> companies, display_name, role 'admin'|'editor', created_at)

-- Dados por empresa (todas com company_id NOT NULL, carimbado por trigger app_private.set_company_id)
-- items(id, category, name, unit, qty, min, ideal, avg_cost, company_id)
-- movements(id, type, item_id, item_name, category_key, unit, qty, unit_value, total_value, branch,
--           withdrawal_name, note, occurred_at, registered_by, invoice_id, reason, company_id)
-- categories(company_id, key, label, color)          pk (company_id, key)
-- branches(company_id, key, label)                   pk (company_id, key)
-- audit_log(id, entity_type, entity_id, action, description, snapshot, performed_by, occurred_at, company_id)
-- invoices(id, supplier_cnpj, supplier_name, number, series, access_key, issue_date, total_value,
--          item_count, xml_content, imported_by, imported_at, company_id)
-- item_supplier_links(company_id, supplier_cnpj, ean, item_id, updated_at)   pk (company_id, supplier_cnpj, ean)
-- users: tabela antiga (legado, sem acesso por API; pode ser removida)

-- Segurança: RLS ligado em tudo; nenhum acesso para o papel `anon` nas tabelas.
-- Políticas (papel authenticated, sempre filtrando por app_private.my_company()):
--   SELECT em: items, movements, categories, branches, audit_log, invoices, item_supplier_links,
--              profiles (da empresa), companies (a própria)
--   INSERT/UPDATE em items (membros)
--   INSERT/UPDATE/DELETE em categories e INSERT/UPDATE em branches (somente admin)
--   UPDATE em companies (somente admin; colunas name e logo_url)
--   movements, audit_log, invoices, item_supplier_links: escrita só via funções (RPC)

-- Funções (security definer, sempre filtram pela empresa de quem chama; app_private.ctx() exige login):
--   criar_item_inicial, registrar_entrada, registrar_saida, registrar_saida_v2 (com motivo),
--   importar_nota_fiscal, excluir_item*, excluir_movimento*, purgar_periodo* (*somente admin),
--   estoque_em_data, get_db_size, painel_publico(p_token) (única liberada ao público, leitura)
-- Schema app_private (não exposto pela API): my_company, my_role, ctx, set_company_id,
--   criar_usuario, teste_isolamento, teste_fase2, teste_exclusoes (testes que desfazem tudo).
-- Edge Function admin-usuarios: admin gerencia pessoas da própria empresa (listar/criar/atualizar/excluir).

-- v1.7: administração da plataforma e solicitações de cadastro
-- platform_admins(user_id pk, created_at)        -- contas sem empresa que administram a plataforma (sem acesso por API)
-- signup_requests(id, created_at, full_name, email, phone, company_name, cnpj, city, segment, message,
--                 status 'novo'|'em_contato'|'aprovado'|'recusado', notes, company_id, handled_at)  -- sem acesso por API
-- solicitar_cadastro(...)  anon+authenticated: grava solicitação (valida, anti-duplicidade, limite por hora, campo isca)
-- eh_plataforma(), plataforma_solicitacoes, plataforma_atualizar_solicitacao, plataforma_empresas,
-- plataforma_criar_empresa (cria empresa + categorias/filial padrão), plataforma_set_ativa, plataforma_renomear_empresa
--   → só authenticated e só quem está em platform_admins
-- Empresa inativa (companies.active=false): app_private.my_company/my_role/ctx deixam de reconhecer seus usuários.
-- Edge Function admin-usuarios v2: administrador da plataforma informa company_id e gerencia pessoas de qualquer empresa.
-- app_private.teste_plataforma(): prova de isolamento da plataforma (desfaz tudo ao final).
