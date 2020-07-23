{% macro synapse__list_relations_without_caching(information_schema, schema) %}
  {% call statement('list_relations_without_caching', fetch_result=True) -%}
    select
      table_catalog as [database],
      table_name as [name],
      table_schema as [schema],
      case when table_type = 'BASE TABLE' then 'table'
           when table_type = 'VIEW' then 'view'
           else table_type
      end as table_type
    from {{ information_schema }}.tables
    where table_schema like '{{ schema }}'
      and table_catalog like '{{ information_schema.database.lower() }}'
  {% endcall %}
  {{ return(load_result('list_relations_without_caching').table) }}
{% endmacro %}

{% macro synapse__list_schemas(database) %}
  {% call statement('list_schemas', fetch_result=True, auto_begin=False) -%}
    select  name as [schema]
    from sys.schemas
  {% endcall %}
  {{ return(load_result('list_schemas').table) }}
{% endmacro %}

{% macro synapse__create_schema(database_name, schema_name) -%}
  {% call statement('create_schema') -%}
    {%- set quote_none = schema_name | replace('"', "") -%}
    {%- set quote_single = schema_name | replace('"', "'") -%}
    IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = {{ quote_single }})
    BEGIN
    EXEC('CREATE SCHEMA {{ quote_none }}')
    END
  {% endcall %}
{% endmacro %}

{% macro synapse__drop_schema(database_name, schema_name) -%}
  {% call statement('drop_schema') -%}
    drop schema if exists {{database_name}}.{{schema_name}}
  {% endcall %}
{% endmacro %}

{# TODO make this function just a wrapper of synapse__drop_relation_script #}
{% macro synapse__drop_relation(relation) -%}
  {% if relation.type == 'view' -%}
   {% set object_id_type = 'V' %}
   {% elif relation.type == 'table'%}
   {% set object_id_type = 'U' %}
   {%- else -%} invalid target name
   {% endif %}
  {% call statement('drop_relation', auto_begin=False) -%}
    if object_id ('{{ relation.schema }}.{{ relation.identifier }}','{{ object_id_type }}') is not null
      begin
      drop {{ relation.type }} {{ relation.schema }}.{{ relation.identifier }}
      end
  {%- endcall %}
{% endmacro %}

{% macro synapse__drop_relation_script(relation) -%}
  {% if relation.type == 'view' -%}
   {% set object_id_type = 'V' %}
   {% elif relation.type == 'table'%}
   {% set object_id_type = 'U' %}
   {%- else -%} invalid target name
   {% endif %}
  if object_id ('{{ relation.schema }}.{{ relation.identifier }}','{{ object_id_type }}') is not null
      begin
      drop {{ relation.type }} {{ relation.schema }}.{{ relation.identifier }}
      end
{% endmacro %}

{% macro synapse__check_schema_exists(database, schema) -%}
  {% call statement('check_schema_exists', fetch_result=True, auto_begin=False) -%}
    --USE {{ database_name }}
    SELECT count(*) as schema_exist FROM sys.schemas WHERE name = '{{ schema }}'
  {%- endcall %}
  {{ return(load_result('check_schema_exists').table) }}
{% endmacro %}

{% macro synapse__create_view_as(relation, sql) -%}
  create view {{ relation.schema }}.{{ relation.identifier }} as
    {{ sql }}
{% endmacro %}


{# TODO Actually Implement the rename index piece #}
{# TODO instead of deleting it...  #}
{% macro synapse__rename_relation(from_relation, to_relation) -%}
  {% call statement('rename_relation') -%}
  
    rename object {{ from_relation.schema }}.{{ from_relation.identifier }} to {{ to_relation.identifier }}
  {%- endcall %}
{% endmacro %}

{% macro synapse__create_clustered_columnstore_index(relation) -%}
  {%- set cci_name = relation.schema ~ '_' ~ relation.identifier ~ '_cci' -%}
  {%- set relation_name = relation.schema ~ '_' ~ relation.identifier -%}
  {%- set full_relation = relation.schema ~ '.' ~ relation.identifier -%}
  if object_id ('{{relation_name}}.{{cci_name}}','U') is not null
      begin
      drop index {{relation_name}}.{{cci_name}}
      end

  CREATE CLUSTERED COLUMNSTORE INDEX {{cci_name}}
    ON {{full_relation}}
{% endmacro %}

{% macro synapse__create_table_as(temporary, relation, sql) -%}
   {%- set as_columnstore = config.get('as_columnstore', default=true) -%}
   {% set tmp_relation = relation.incorporate(
   path={"identifier": relation.identifier.replace("#", "") ~ '_temp_view'},
   type='view')-%}
   {%- set temp_view_sql = sql.replace("'", "''") -%}

   {{ synapse__drop_relation_script(tmp_relation) }}

   {{ synapse__drop_relation_script(relation) }}

   EXEC('create view {{ tmp_relation.schema }}.{{ tmp_relation.identifier }} as
    {{ temp_view_sql }}
    ');

  CREATE TABLE {{ relation.schema }}.{{ relation.identifier }}
    WITH(DISTRIBUTION = ROUND_ROBIN)
    AS (SELECT * FROM {{ tmp_relation.schema }}.{{ tmp_relation.identifier }})

   {{ synapse__drop_relation_script(tmp_relation) }}

{% endmacro %}

{% macro synapse__insert_into_from(to_relation, from_relation) -%}
  {%- set full_to_relation = to_relation.schema ~ '.' ~ to_relation.identifier -%}
  {%- set full_from_relation = from_relation.schema ~ '.' ~ from_relation.identifier -%}

  SELECT * INTO {{full_to_relation}} FROM {{full_from_relation}}

{% endmacro %}

{% macro synapse__current_timestamp() -%}
  getdate()
{%- endmacro %}

{% macro synapse__get_columns_in_relation(relation) -%}
  {% call statement('get_columns_in_relation', fetch_result=True) %}
      SELECT
          column_name,
          data_type,
          character_maximum_length,
          numeric_precision,
          numeric_scale
      FROM
          (select
              ordinal_position,
              column_name,
              data_type,
              character_maximum_length,
              numeric_precision,
              numeric_scale
          from INFORMATION_SCHEMA.COLUMNS
          where table_name = '{{ relation.identifier }}'
            and table_schema = '{{ relation.schema }}') cols


  {% endcall %}
  {% set table = load_result('get_columns_in_relation').table %}
  {{ return(sql_convert_columns_in_relation(table)) }}
{% endmacro %}

{% macro synapse__make_temp_relation(base_relation, suffix) %}
    {% set tmp_identifier = '#' ~  base_relation.identifier ~ suffix %}
    {% set tmp_relation = base_relation.incorporate(
                                path={"identifier": tmp_identifier}) -%}

    {% do return(tmp_relation) %}
{% endmacro %}