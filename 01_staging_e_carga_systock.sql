-- ============================================================================
-- CASE TÉCNICO SYSTOCK — Analista de Integração de Dados
-- Script: Staging, Validação e Carga (ETL) para as 5 tabelas do teste
-- Autor: Gabriel Azevedo Martins
-- ============================================================================
--
-- ESTRATÉGIA:
-- 1) Criar tabelas finais no schema "systock" (o schema "public" pode não
--    ter permissão de CREATE para o usuário da instância — comum em
--    PostgreSQL 15+, que tira privilégios de "public" por padrão),
--    corrigindo também os erros estruturais das DDLs originais
--    (documentados abaixo, item "ERROS INTENCIONAIS IDENTIFICADOS").
-- 2) Criar tabelas de STAGING (schema "staging"), todas com colunas TEXT,
--    sem constraints, para receber os dados brutos das planilhas/CSV sem
--    risco de erro de tipo ou de NOT NULL na importação.
-- 3) Importar cada arquivo fonte (via DBeaver Data Transfer) para a tabela
--    de staging correspondente.
-- 4) Rodar os INSERT...SELECT abaixo, que fazem CAST, tratamento de nulos/
--    vazios e filtragem de linhas inválidas (lixo de planilha, linhas em
--    branco, rodapés) antes de popular a tabela final.
--
-- ============================================================================
-- ERROS INTENCIONAIS IDENTIFICADOS NAS DDLs ORIGINAIS DO CASE
-- ============================================================================
-- 1. entradas_mercadoria: PK referenciava a coluna "ordem_compra", que não
--    existia na definição da tabela. Adicionada a coluna ordem_compra float8,
--    já que a observação do enunciado diz que a entrada se relaciona ao
--    pedido de compra por esse campo.
-- 2. produtos_filial: faltava vírgula antes de CONSTRAINT (erro de sintaxe
--    que impede a criação da tabela) e a PK usava "idproduto", mas a coluna
--    real se chama "produto_id". Também a coluna "idfonecedor" está com
--    grafia diferente de "fornecedor_id"/"idfornecedor" usada nas demais
--    tabelas — mantive o nome original da DDL, mas seria um ponto a validar
--    com o cliente (Parte 4).
-- 3. fornecedor: PK referenciava "idproduto", coluna inexistente e sem
--    sentido semântico numa tabela de fornecedores (1 fornecedor pode ter
--    N produtos). Removida a referência a idproduto da PK.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS systock;

-- ============================================================================
-- PARTE A — TABELAS FINAIS (corrigidas) — schema "systock"
-- ============================================================================

DROP TABLE IF EXISTS systock.venda CASCADE;
CREATE TABLE systock.venda (
    venda_id        int8 NOT NULL,
    data_emissao    date NOT NULL,
    horariomov      varchar(8) DEFAULT '00:00:00'::character varying NOT NULL,
    produto_id      varchar(25) DEFAULT ''::character varying NOT NULL,
    qtde_vendida    float8 NULL,
    valor_unitario  numeric(12,4) DEFAULT 0 NOT NULL,
    filial_id       int8 DEFAULT 1 NOT NULL,
    item            int4 DEFAULT 0 NOT NULL,
    unidade_medida  varchar(3) NULL,
    CONSTRAINT pk_venda PRIMARY KEY (filial_id, venda_id, data_emissao, produto_id, item, horariomov)
);

DROP TABLE IF EXISTS systock.pedido_compra CASCADE;
CREATE TABLE systock.pedido_compra (
    pedido_id           float8 DEFAULT 0 NOT NULL,
    data_pedido         date NULL,
    item                float8 DEFAULT 0 NOT NULL,
    produto_id          varchar(25) DEFAULT '0' NOT NULL,
    descricao_produto   varchar(255) NULL,
    ordem_compra        float8 DEFAULT 0 NOT NULL,
    qtde_pedida         float8 NULL,
    filial_id           int4 NULL,
    data_entrega        date NULL,
    qtde_entregue       float8 DEFAULT 0 NOT NULL,
    qtde_pendente       float8 DEFAULT 0 NOT NULL,
    preco_compra        float8 DEFAULT 0 NULL,
    fornecedor_id       int4 DEFAULT 0 NULL,
    CONSTRAINT pk_pedido_compra PRIMARY KEY (pedido_id, produto_id, item)
);

DROP TABLE IF EXISTS systock.entradas_mercadoria CASCADE;
CREATE TABLE systock.entradas_mercadoria (
    data_entrada     date NULL,
    nro_nfe          varchar(255) NOT NULL,
    item             float8 DEFAULT 0 NOT NULL,
    produto_id       varchar(25) DEFAULT '0' NOT NULL,
    descricao_produto varchar(255) NULL,
    qtde_recebida    float8 NULL,
    filial_id        int4 NULL,
    custo_unitario   numeric(12,4) DEFAULT 0 NOT NULL,
    ordem_compra     float8 DEFAULT 0 NOT NULL,  -- corrigido: coluna ausente na DDL original
    CONSTRAINT pk_entradas_mercadoria PRIMARY KEY (ordem_compra, item, produto_id, nro_nfe)
);

DROP TABLE IF EXISTS systock.produtos_filial CASCADE;
CREATE TABLE systock.produtos_filial (
    filial_id       int4 NULL,
    produto_id      varchar(255) NOT NULL,
    descricao       varchar(255) NOT NULL,       -- corrigido: "decricao" -> "descricao"
    estoque         float8 DEFAULT 0 NOT NULL,
    preco_unitario  float8 DEFAULT 0 NOT NULL,
    preco_compra    float8 DEFAULT 0 NOT NULL,
    preco_venda     float8 DEFAULT 0 NOT NULL,
    idfonecedor     int4 NULL,
    CONSTRAINT pk_produtos_filial PRIMARY KEY (filial_id, produto_id)  -- corrigido: idproduto -> produto_id
);

DROP TABLE IF EXISTS systock.fornecedor CASCADE;
CREATE TABLE systock.fornecedor (
    idfornecedor   varchar(25) NOT NULL,
    razao_social  varchar(255) NOT NULL,
    CONSTRAINT pk_fornecedor PRIMARY KEY (idfornecedor)  -- corrigido: removida ref. a idproduto
);

-- ============================================================================
-- PARTE B — TABELAS DE STAGING (texto puro, sem constraints)
-- ============================================================================

DROP TABLE IF EXISTS staging.venda_raw;
CREATE TABLE staging.venda_raw (
    venda_id        text,
    data_emissao    text,
    horariomov      text,
    produto_id      text,
    qtde_vendida    text,
    valor_unitario  text,
    filial_id       text,
    item            text,
    unidade_medida  text
);

DROP TABLE IF EXISTS staging.pedido_compra_raw;
CREATE TABLE staging.pedido_compra_raw (
    pedido_id          text,
    data_pedido        text,
    item               text,
    produto_id         text,
    descricao_produto  text,
    ordem_compra       text,
    qtde_pedida        text,
    filial_id          text,
    data_entrega       text,
    qtde_entregue      text,
    qtde_pendente      text,
    preco_compra       text,
    fornecedor_id      text
);

DROP TABLE IF EXISTS staging.entradas_mercadoria_raw;
CREATE TABLE staging.entradas_mercadoria_raw (
    data_entrada       text,
    nro_nfe            text,
    item               text,
    produto_id         text,
    descricao_produto  text,
    qtde_recebida      text,
    filial_id          text,
    custo_unitario     text,
    ordem_compra       text
);

DROP TABLE IF EXISTS staging.produtos_filial_raw;
CREATE TABLE staging.produtos_filial_raw (
    filial_id       text,
    produto_id      text,
    descricao       text,
    estoque         text,
    preco_unitario  text,
    preco_compra    text,
    preco_venda     text,
    idfonecedor     text
);

DROP TABLE IF EXISTS staging.fornecedor_raw;
CREATE TABLE staging.fornecedor_raw (
    idfornecedor   text,
    razao_social  text
);

-- ============================================================================
-- PARTE C — IMPORTAÇÃO ( via DBeaver: botão direito na tabela staging.*
-- -> Import Data -> selecionei o CSV/aba correspondente da planilha ->
-- mapiei 1:1 pelas colunas acima, todas como "existing" -> Proceed)
-- ============================================================================

-- ============================================================================
-- FUNÇÃO AUXILIAR: normaliza número em formato BR ("1.234,56") para o
-- formato aceito pelo Postgres ("1234.56"). Necessária porque a planilha
-- fonte usa vírgula como separador decimal (ex: "78,93"), o que quebra
-- CAST direto para numeric/float8.
-- ============================================================================
CREATE OR REPLACE FUNCTION staging.br_to_num(txt text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT NULLIF(trim(replace(replace(trim(txt), '.', ''), ',', '.')), '')
$$;

-- ============================================================================
-- FUNÇÃO AUXILIAR: parse de data tolerante a formato misto na origem.
-- A planilha/CSV traz datas em pelo menos dois formatos diferentes
-- (ex: "1/28/2025" em MM/DD/YYYY e "2025-01-02" já em ISO YYYY-MM-DD,
-- provavelmente porque uma coluna foi reconhecida como tipo date na
-- exportação e outra ficou como texto puro). Esta função tenta, nesta
-- ordem: ISO (YYYY-MM-DD), depois MM/DD/YYYY, depois DD/MM/YYYY.
-- Se nenhuma bater, retorna NULL em vez de estourar erro (a linha então
-- é descartada ou fica com data nula, dependendo do filtro do INSERT).
-- ============================================================================
CREATE OR REPLACE FUNCTION staging.parse_data(txt text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v text := NULLIF(trim(txt), '');
BEGIN
    IF v IS NULL THEN
        RETURN NULL;
    END IF;

    -- Formato ISO: YYYY-MM-DD
    IF v ~ '^\d{4}-\d{2}-\d{2}$' THEN
        RETURN v::date;
    END IF;

    -- Formato MM/DD/YYYY (americano)
    IF v ~ '^\d{1,2}/\d{1,2}/\d{4}$' THEN
        BEGIN
            RETURN to_date(v, 'MM/DD/YYYY');
        EXCEPTION WHEN OTHERS THEN
            -- se mês/dia invertido não bater em MM/DD, tenta DD/MM
            BEGIN
                RETURN to_date(v, 'DD/MM/YYYY');
            EXCEPTION WHEN OTHERS THEN
                RETURN NULL;
            END;
        END;
    END IF;

    RETURN NULL;
END;
$$;

-- ============================================================================
-- PARTE D — CARGA FINAL: CAST + VALIDAÇÃO + FILTRO DE LIXO
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) VENDA
-- ---------------------------------------------------------------------------
INSERT INTO systock.venda
    (venda_id, data_emissao, horariomov, produto_id, qtde_vendida,
     valor_unitario, filial_id, item, unidade_medida)
SELECT
    venda_id::int8,
    staging.parse_data(data_emissao),
    COALESCE(NULLIF(trim(horariomov), ''), '00:00:00'),
    COALESCE(NULLIF(trim(produto_id), ''), ''),
    staging.br_to_num(qtde_vendida)::float8,
    COALESCE(staging.br_to_num(valor_unitario), '0')::numeric(12,4),
    COALESCE(NULLIF(trim(filial_id), ''), '1')::int8,
    COALESCE(NULLIF(trim(item), ''), '0')::int4,
    NULLIF(trim(unidade_medida), '')
FROM staging.venda_raw
WHERE venda_id IS NOT NULL
  AND trim(venda_id) <> ''
  AND data_emissao IS NOT NULL
  AND trim(data_emissao) <> ''
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2) PEDIDO_COMPRA
-- ---------------------------------------------------------------------------
INSERT INTO systock.pedido_compra
    (pedido_id, data_pedido, item, produto_id, descricao_produto, ordem_compra,
     qtde_pedida, filial_id, data_entrega, qtde_entregue, qtde_pendente,
     preco_compra, fornecedor_id)
SELECT
    COALESCE(staging.br_to_num(pedido_id), '0')::float8,
    staging.parse_data(data_pedido),
    COALESCE(staging.br_to_num(item), '0')::float8,
    COALESCE(NULLIF(trim(produto_id), ''), '0'),
    NULLIF(trim(descricao_produto), ''),
    COALESCE(staging.br_to_num(ordem_compra), '0')::float8,
    staging.br_to_num(qtde_pedida)::float8,
    NULLIF(trim(filial_id), '')::int4,
    staging.parse_data(data_entrega),
    COALESCE(staging.br_to_num(qtde_entregue), '0')::float8,
    COALESCE(staging.br_to_num(qtde_pendente), '0')::float8,
    staging.br_to_num(preco_compra)::float8,
    NULLIF(trim(fornecedor_id), '')::int4
FROM staging.pedido_compra_raw
WHERE produto_id IS NOT NULL
  AND trim(produto_id) <> ''
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) ENTRADAS_MERCADORIA
-- ---------------------------------------------------------------------------
INSERT INTO systock.entradas_mercadoria
    (data_entrada, nro_nfe, item, produto_id, descricao_produto,
     qtde_recebida, filial_id, custo_unitario, ordem_compra)
SELECT
    staging.parse_data(data_entrada),
    trim(nro_nfe),
    COALESCE(staging.br_to_num(item), '0')::float8,
    COALESCE(NULLIF(trim(produto_id), ''), '0'),
    NULLIF(trim(descricao_produto), ''),
    staging.br_to_num(qtde_recebida)::float8,
    NULLIF(trim(filial_id), '')::int4,
    COALESCE(staging.br_to_num(custo_unitario), '0')::numeric(12,4),
    COALESCE(staging.br_to_num(ordem_compra), '0')::float8
FROM staging.entradas_mercadoria_raw
WHERE nro_nfe IS NOT NULL
  AND trim(nro_nfe) <> ''
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4) PRODUTOS_FILIAL
-- ---------------------------------------------------------------------------
INSERT INTO systock.produtos_filial
    (filial_id, produto_id, descricao, estoque, preco_unitario,
     preco_compra, preco_venda, idfonecedor)
SELECT
    NULLIF(trim(filial_id), '')::int4,
    trim(produto_id),
    COALESCE(NULLIF(trim(descricao), ''), 'SEM DESCRICAO'),
    COALESCE(staging.br_to_num(estoque), '0')::float8,
    COALESCE(staging.br_to_num(preco_unitario), '0')::float8,
    COALESCE(staging.br_to_num(preco_compra), '0')::float8,
    COALESCE(staging.br_to_num(preco_venda), '0')::float8,
    NULLIF(trim(idfonecedor), '')::int4
FROM staging.produtos_filial_raw
WHERE produto_id IS NOT NULL
  AND trim(produto_id) <> ''
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5) FORNECEDOR
-- ---------------------------------------------------------------------------
INSERT INTO systock.fornecedor
    (idfornecedor, razao_social)
SELECT
    trim(idfornecedor),
    trim(razao_social)
FROM staging.fornecedor_raw
WHERE idfornecedor IS NOT NULL
  AND trim(idfornecedor) <> ''
ON CONFLICT DO NOTHING;

-- ============================================================================
-- PARTE E — CONFERÊNCIA PÓS-CARGA (contagem de linhas: staging vs final)
-- ============================================================================
SELECT 'venda' AS tabela,
       (SELECT count(*) FROM staging.venda_raw) AS staging_qtd,
       (SELECT count(*) FROM systock.venda) AS final_qtd
UNION ALL
SELECT 'pedido_compra',
       (SELECT count(*) FROM staging.pedido_compra_raw),
       (SELECT count(*) FROM systock.pedido_compra)
UNION ALL
SELECT 'entradas_mercadoria',
       (SELECT count(*) FROM staging.entradas_mercadoria_raw),
       (SELECT count(*) FROM systock.entradas_mercadoria)
UNION ALL
SELECT 'produtos_filial',
       (SELECT count(*) FROM staging.produtos_filial_raw),
       (SELECT count(*) FROM systock.produtos_filial)
UNION ALL
SELECT 'fornecedor',
       (SELECT count(*) FROM staging.fornecedor_raw),
       (SELECT count(*) FROM systock.fornecedor);

