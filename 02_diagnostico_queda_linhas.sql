-- ============================================================================
-- DIAGNÓSTICO: por que staging_qtd >> final_qtd?
-- Rodar tabela por tabela, trocando os nomes conforme necessário.
-- Exemplo abaixo usando VENDA.
-- ============================================================================

-- 1) Quantas linhas do staging JÁ vêm com a chave (venda_id) nula/vazia?
--    (isso mede o que o WHERE está descartando de fato)
SELECT
    count(*) AS total_staging,
    count(*) FILTER (WHERE venda_id IS NULL OR trim(venda_id) = '') AS sem_venda_id,
    count(*) FILTER (WHERE data_emissao IS NULL OR trim(data_emissao) = '') AS sem_data_emissao
FROM staging.venda_raw;

-- 2) Das linhas que TÊM venda_id e data_emissao preenchidos, quantas têm
--    chave primária (filial_id, venda_id, data_emissao, produto_id, item,
--    horariomov) REPETIDA? Se esse número for alto, o problema é
--    duplicidade real de chave (causa do ON CONFLICT DO NOTHING descartar).
SELECT
    filial_id, venda_id, data_emissao, produto_id, item, horariomov,
    count(*) AS ocorrencias
FROM staging.venda_raw
WHERE venda_id IS NOT NULL AND trim(venda_id) <> ''
  AND data_emissao IS NOT NULL AND trim(data_emissao) <> ''
GROUP BY filial_id, venda_id, data_emissao, produto_id, item, horariomov
HAVING count(*) > 1
ORDER BY ocorrencias DESC
LIMIT 20;

-- 3) Quantas linhas têm data_emissao preenchida, mas que o parse_data()
--    não conseguiu converter (viraria NULL, colidindo todas na mesma
--    "chave nula" e sendo descartadas ou sobrescritas)?
SELECT
    data_emissao AS valor_original,
    staging.parse_data(data_emissao) AS data_convertida,
    count(*) AS qtd
FROM staging.venda_raw
WHERE data_emissao IS NOT NULL AND trim(data_emissao) <> ''
  AND staging.parse_data(data_emissao) IS NULL
GROUP BY data_emissao
ORDER BY qtd DESC
LIMIT 20;

-- 4) Visão consolidada: quantas linhas passariam pelo WHERE do INSERT,
--    e quantas dessas são de fato distintas pela chave primária?
SELECT
    count(*) AS passaria_no_where,
    count(DISTINCT (filial_id, venda_id, data_emissao, produto_id, item, horariomov)) AS chaves_distintas
FROM staging.venda_raw
WHERE venda_id IS NOT NULL AND trim(venda_id) <> ''
  AND data_emissao IS NOT NULL AND trim(data_emissao) <> '';


-- PEDIDO_COMPRA (PK: pedido_id, produto_id, item)
SELECT
    count(*) AS passaria_no_where,
    count(DISTINCT (pedido_id, produto_id, item)) AS chaves_distintas
FROM staging.pedido_compra_raw
WHERE produto_id IS NOT NULL AND trim(produto_id) <> '';

-- ENTRADAS_MERCADORIA (PK: ordem_compra, item, produto_id, nro_nfe)
SELECT
    count(*) AS passaria_no_where,
    count(DISTINCT (ordem_compra, item, produto_id, nro_nfe)) AS chaves_distintas
FROM staging.entradas_mercadoria_raw
WHERE nro_nfe IS NOT NULL AND trim(nro_nfe) <> '';

-- PRODUTOS_FILIAL (PK: filial_id, produto_id)
SELECT
    count(*) AS passaria_no_where,
    count(DISTINCT (filial_id, produto_id)) AS chaves_distintas
FROM staging.produtos_filial_raw
WHERE produto_id IS NOT NULL AND trim(produto_id) <> '';

-- FORNECEDOR (PK: idfornecedor)
SELECT
    count(*) AS passaria_no_where,
    count(DISTINCT idfornecedor) AS chaves_distintas
FROM staging.fornecedor_raw
WHERE idfornecedor IS NOT NULL AND trim(idfornecedor) <> '';