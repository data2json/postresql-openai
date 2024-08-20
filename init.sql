SET client_encoding = 'UTF8';


CREATE EXTENSION IF NOT EXISTS plpython3u WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plpython3u; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION plpython3u IS 'PL/Python3U untrusted procedural language';


--
-- Name: build_and_submit_conversation(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.build_and_submit_conversation(template_name text, params text) RETURNS text
    LANGUAGE plpython3u
    AS $$
import sys
import os
import json

# Ensure the virtual environment is in the Python path
venv_site_packages = '/opt/venv/lib/python3.11/site-packages'
if venv_site_packages not in sys.path:
    sys.path.insert(0, venv_site_packages)

try:
    from openai import AsyncOpenAI
    import asyncio
except ImportError as e:
    return f"Error importing required modules: {str(e)}"

# Fetch the template
template_query = plpy.execute(f"SELECT template FROM conversation_templates WHERE name = '{template_name}'")
if len(template_query) == 0:
    return f"Error: Template '{template_name}' not found"

template = template_query[0]['template']

# Ensure template is a list
if isinstance(template, str):
    try:
        template = json.loads(template)
    except json.JSONDecodeError:
        return "Error: Invalid JSON format for template"

# Parse params
try:
    params_dict = json.loads(params)
except json.JSONDecodeError:
    return "Error: Invalid JSON format for params"

# Build the conversation by replacing placeholders with params
conversation = []
for message in template:
    if isinstance(message, dict) and 'role' in message and 'content' in message:
        content = message['content']
        for key, value in params_dict.items():
            content = content.replace(f"{{{key}}}", str(value))
        conversation.append({"role": message['role'], "content": content})
    else:
        plpy.warning(f"Skipping invalid message: {message}")

async def main(conversation):
    client = AsyncOpenAI(
        api_key=os.environ.get("OPENAI_API_KEY"),
        base_url=os.environ.get("OPENAI_API_BASE")
    )
    try:
        chat_completion = await client.chat.completions.create(
            messages=conversation,
            model="gpt-3.5-turbo",
        )
        return chat_completion.choices[0].message.content
    except Exception as e:
        return f"Error calling OpenAI API: {str(e)}"

def run_async(conversation):
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        return loop.run_until_complete(main(conversation))
    finally:
        loop.close()

return run_async(conversation)
$$;


ALTER FUNCTION public.build_and_submit_conversation(template_name text, params text) OWNER TO postgres;

--
-- Name: check_openai_import(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_openai_import() RETURNS text
    LANGUAGE plpython3u
    AS $$
try:
    import openai
    return f"OpenAI version: {openai.__version__}"
except ImportError as e:
    return str(e)
$$;


ALTER FUNCTION public.check_openai_import() OWNER TO postgres;

--
-- Name: check_python_env(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_python_env() RETURNS text
    LANGUAGE plpython3u
    AS $$
import sys
return sys.version
$$;


ALTER FUNCTION public.check_python_env() OWNER TO postgres;

--
-- Name: check_python_path(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_python_path() RETURNS text
    LANGUAGE plpython3u
    AS $$
import sys
return '\n'.join(sys.path)
$$;


ALTER FUNCTION public.check_python_path() OWNER TO postgres;

--
-- Name: check_typing_extensions(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_typing_extensions() RETURNS text
    LANGUAGE plpython3u
    AS $$
try:
    import typing_extensions
    return f"typing_extensions version: {typing_extensions.__version__}"
except ImportError as e:
    return str(e)
except AttributeError:
    return f"typing_extensions is installed, but __version__ is not available"
$$;


ALTER FUNCTION public.check_typing_extensions() OWNER TO postgres;

--
-- Name: get_input_context(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_input_context(p_context text) RETURNS text
    LANGUAGE sql STABLE
    AS $_$
    SELECT $1;
$_$;


ALTER FUNCTION public.get_input_context(p_context text) OWNER TO postgres;

--
-- Name: meta_cognitive_workflow(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.meta_cognitive_workflow(input_context text) RETURNS TABLE(input_data text, analysis text, class_labels text, chosen_template text, filled_template text, final_completion text, final_answer text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_analysis TEXT;
    v_labels TEXT;
    v_template_number TEXT;
    v_filled_template TEXT;
    v_completion TEXT;
    v_answer TEXT;
BEGIN
    -- Initial analysis
    SELECT json_build_object(
        'main_topic', build_and_submit_conversation('analysis_questions',
            json_build_object(
                'context', input_context,
                'question', 'What is the main topic of this context?',
                'language', 'en'
            )::text
        ),
        'key_concepts', build_and_submit_conversation('analysis_questions',
            json_build_object(
                'context', input_context,
                'question', 'What are the key concepts or ideas mentioned?',
                'language', 'en'
            )::text
        ),
        'reasoning_type', build_and_submit_conversation('analysis_questions',
            json_build_object(
                'context', input_context,
                'question', 'What type of reasoning would be most appropriate (deductive, inductive, abductive, analogical)?',
                'language', 'en'
            )::text
        )
    )::text INTO v_analysis;

    -- Generate class labels
    SELECT build_and_submit_conversation('generate_class_labels',
        json_build_object(
            'analysis', v_analysis,
            'language', 'en'
        )::text
    ) INTO v_labels;

    -- Choose template
    SELECT build_and_submit_conversation('choose_template',
        json_build_object(
            'analysis', v_analysis,
            'class_labels', v_labels,
            'language', 'en'
        )::text
    ) INTO v_template_number;

    -- Fill template
    SELECT build_and_submit_conversation('fill_template',
        json_build_object(
            'template', CASE v_template_number
                WHEN '1' THEN 'If {premise1} is true, and {premise2} is true, then {conclusion} must be true.'
                WHEN '2' THEN 'Based on observations {observation1}, {observation2}, and {observation3}, we can generalize that {generalization}.'
                WHEN '3' THEN 'The best explanation for {phenomenon} is {hypothesis} because {reasoning}.'
                WHEN '4' THEN 'Situation {situationA} is similar to situation {situationB} in ways {similarity1} and {similarity2}, so we can infer {inference}.'
                ELSE 'If {premise1} is true, and {premise2} is true, then {conclusion} must be true.'
            END,
            'analysis', v_analysis,
            'class_labels', v_labels,
            'language', 'en'
        )::text
    ) INTO v_filled_template;

    -- Final completion
    SELECT build_and_submit_conversation('final_completion',
        json_build_object(
            'filled_template', v_filled_template,
            'analysis', v_analysis,
            'class_labels', v_labels,
            'language', 'en'
        )::text
    ) INTO v_completion;

    -- Final answer
    SELECT build_and_submit_conversation('final_answer',
        json_build_object(
            'filled_template', v_filled_template,
            'input_data', input_context,
            'language', 'en'
        )::text
    ) INTO v_answer;

    -- Return results
    RETURN QUERY SELECT
        input_context,
        v_analysis,
        v_labels,
        v_template_number,
        v_filled_template,
        v_completion,
        v_answer;
END;
$$;


ALTER FUNCTION public.meta_cognitive_workflow(input_context text) OWNER TO postgres;

--
-- Name: FUNCTION meta_cognitive_workflow(input_context text); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.meta_cognitive_workflow(input_context text) IS 'This function encapsulates the meta-cognitive workflow. It takes an input context as a parameter and returns the results of each step in the workflow.';


--
-- Name: set_venv_python(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_venv_python() RETURNS void
    LANGUAGE plpython3u
    AS $$
import sys
import os

venv_path = '/opt/venv'
venv_site_packages = f'{venv_path}/lib/python3.11/site-packages'

if venv_site_packages not in sys.path:
    sys.path.insert(0, venv_site_packages)

os.environ['VIRTUAL_ENV'] = venv_path
os.environ['PATH'] = f"{venv_path}/bin:{os.environ['PATH']}"
$$;


ALTER FUNCTION public.set_venv_python() OWNER TO postgres;

--
-- Name: update_ai_response(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_ai_response() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    response TEXT;
BEGIN
    -- Call build_and_submit_conversation with the new row's data
    SELECT build_and_submit_conversation('dynamic_response', 
        json_build_object('input', NEW.input_text)::text
    ) INTO response;
    
    -- Update the ai_response column with the returned value
    NEW.ai_response := response;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_ai_response() OWNER TO postgres;

--
-- Name: upsert_conversation_template(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.upsert_conversation_template(p_name text, p_template text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_template JSONB;
BEGIN
    -- Try to parse the input as JSONB
    BEGIN
        v_template := p_template::JSONB;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid JSON format for template';
    END;

    -- Ensure the template is a JSONB array
    IF jsonb_typeof(v_template) != 'array' THEN
        RAISE EXCEPTION 'Template must be a JSON array';
    END IF;

    -- Ensure each element in the array is an object with 'role' and 'content' keys
    FOR i IN 0..jsonb_array_length(v_template) - 1 LOOP
        IF NOT (v_template->i ? 'role' AND v_template->i ? 'content') THEN
            RAISE EXCEPTION 'Each element in the template must have "role" and "content" keys';
        END IF;
    END LOOP;

    INSERT INTO conversation_templates (name, template)
    VALUES (p_name, v_template)
    ON CONFLICT (name)
    DO UPDATE SET template = v_template;
END;
$$;


ALTER FUNCTION public.upsert_conversation_template(p_name text, p_template text) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ai_responses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ai_responses (
    id integer NOT NULL,
    input_text text NOT NULL,
    ai_response text
);


ALTER TABLE public.ai_responses OWNER TO postgres;

--
-- Name: ai_responses_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.ai_responses_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.ai_responses_id_seq OWNER TO postgres;

--
-- Name: ai_responses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.ai_responses_id_seq OWNED BY public.ai_responses.id;


--
-- Name: conversation_templates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.conversation_templates (
    id integer NOT NULL,
    name text NOT NULL,
    template jsonb NOT NULL
);


ALTER TABLE public.conversation_templates OWNER TO postgres;

--
-- Name: conversation_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.conversation_templates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.conversation_templates_id_seq OWNER TO postgres;

--
-- Name: conversation_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.conversation_templates_id_seq OWNED BY public.conversation_templates.id;


--
-- Name: meta_cognitive_workflow; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.meta_cognitive_workflow AS
 WITH RECURSIVE input_data AS (
         SELECT public.get_input_context(NULL::text) AS context
        ), initial_analysis AS (
         SELECT public.build_and_submit_conversation('analysis_questions'::text, (json_build_object('context', ( SELECT input_data.context
                   FROM input_data), 'question', 'What is the main topic of this context?', 'language', 'en'))::text) AS main_topic,
            public.build_and_submit_conversation('analysis_questions'::text, (json_build_object('context', ( SELECT input_data.context
                   FROM input_data), 'question', 'What are the key concepts or ideas mentioned?', 'language', 'en'))::text) AS key_concepts,
            public.build_and_submit_conversation('analysis_questions'::text, (json_build_object('context', ( SELECT input_data.context
                   FROM input_data), 'question', 'What type of reasoning would be most appropriate (deductive, inductive, abductive, analogical)?', 'language', 'en'))::text) AS reasoning_type
        ), analysis_summary AS (
         SELECT (json_build_object('main_topic', initial_analysis.main_topic, 'key_concepts', initial_analysis.key_concepts, 'reasoning_type', initial_analysis.reasoning_type))::text AS summary
           FROM initial_analysis
        ), class_labels AS (
         SELECT public.build_and_submit_conversation('generate_class_labels'::text, (json_build_object('analysis', ( SELECT analysis_summary.summary
                   FROM analysis_summary), 'language', 'en'))::text) AS labels
        ), chosen_template AS (
         SELECT public.build_and_submit_conversation('choose_template'::text, (json_build_object('analysis', ( SELECT analysis_summary.summary
                   FROM analysis_summary), 'class_labels', ( SELECT class_labels.labels
                   FROM class_labels), 'language', 'en'))::text) AS template_number
        ), filled_template AS (
         SELECT public.build_and_submit_conversation('fill_template'::text, (json_build_object('template',
                CASE ( SELECT chosen_template.template_number
                       FROM chosen_template)
                    WHEN '1'::text THEN 'If {premise1} is true, and {premise2} is true, then {conclusion} must be true.'::text
                    WHEN '2'::text THEN 'Based on observations {observation1}, {observation2}, and {observation3}, we can generalize that {generalization}.'::text
                    WHEN '3'::text THEN 'The best explanation for {phenomenon} is {hypothesis} because {reasoning}.'::text
                    WHEN '4'::text THEN 'Situation {situationA} is similar to situation {situationB} in ways {similarity1} and {similarity2}, so we can infer {inference}.'::text
                    ELSE 'If {premise1} is true, and {premise2} is true, then {conclusion} must be true.'::text
                END, 'analysis', ( SELECT analysis_summary.summary
                   FROM analysis_summary), 'class_labels', ( SELECT class_labels.labels
                   FROM class_labels), 'language', 'en'))::text) AS filled_template
        ), final_completion AS (
         SELECT public.build_and_submit_conversation('final_completion'::text, (json_build_object('filled_template', ( SELECT filled_template.filled_template
                   FROM filled_template), 'analysis', ( SELECT analysis_summary.summary
                   FROM analysis_summary), 'class_labels', ( SELECT class_labels.labels
                   FROM class_labels), 'language', 'en'))::text) AS completion
        ), final_answer AS (
         SELECT public.build_and_submit_conversation('final_answer'::text, (json_build_object('filled_template', ( SELECT filled_template.filled_template
                   FROM filled_template), 'input_data', ( SELECT input_data.context
                   FROM input_data), 'language', 'en'))::text) AS answer
        )
 SELECT ( SELECT input_data.context
           FROM input_data) AS input_data,
    ( SELECT analysis_summary.summary
           FROM analysis_summary) AS analysis,
    ( SELECT class_labels.labels
           FROM class_labels) AS class_labels,
    ( SELECT chosen_template.template_number
           FROM chosen_template) AS chosen_template,
    ( SELECT filled_template.filled_template
           FROM filled_template) AS filled_template,
    ( SELECT final_completion.completion
           FROM final_completion) AS final_completion,
    ( SELECT final_answer.answer
           FROM final_answer) AS final_answer;


ALTER VIEW public.meta_cognitive_workflow OWNER TO postgres;

--
-- Name: VIEW meta_cognitive_workflow; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON VIEW public.meta_cognitive_workflow IS 'This view encapsulates the meta-cognitive workflow. To use it, call the view with a specific input context using the get_input_context function.';


--
-- Name: ai_responses id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ai_responses ALTER COLUMN id SET DEFAULT nextval('public.ai_responses_id_seq'::regclass);


--
-- Name: conversation_templates id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.conversation_templates ALTER COLUMN id SET DEFAULT nextval('public.conversation_templates_id_seq'::regclass);




--
-- Data for Name: conversation_templates; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.conversation_templates (id, name, template) FROM stdin;
1	simple_conversation	[{"role": "system", "content": "You are a helpful assistant."}, {"role": "user", "content": "Hello, my name is {name}. {question}"}]
2	dynamic_response	[{"role": "system", "content": "You are a helpful assistant. Respond to the following input concisely."}, {"role": "user", "content": "{input}"}]
3	analysis_questions	[{"role": "system", "content": "You are an expert in analyzing and answering questions about given contexts."}, {"role": "user", "content": "Context: {context}\\n\\nQuestion: {question}\\n\\nProvide an accurate and concise answer."}]
4	generate_class_labels	[{"role": "system", "content": "You are an expert in categorizing and labeling data."}, {"role": "user", "content": "Based on the following analysis, generate a list of accurate value labels:\\n\\nAnalysis: {analysis}\\n\\nProvide your answer as a comma-separated list of labels.\\nOutput only your answer as a comma-separated list of labels."}]
5	choose_template	[{"role": "system", "content": "You are an expert in selecting appropriate reasoning templates."}, {"role": "user", "content": "Based on the following analysis and class labels, choose the most appropriate reasoning template:\\n\\nAnalysis: {analysis}\\nClass Labels: {class_labels}\\n\\nTemplates:\\n1. Deductive Reasoning: \\"If A is true, and B is true, then C must be true.\\"\\n2. Inductive Reasoning: \\"Based on observations X, Y, and Z, we can generalize that...\\"\\n3. Abductive Reasoning: \\"The best explanation for phenomenon P is hypothesis H because...\\"\\n4. Analogical Reasoning: \\"Situation A is similar to situation B in ways X and Y, so we can infer...\\"\\n\\nProvide your answer as the number of the chosen template. Output the number only."}]
6	fill_template	[{"role": "system", "content": "You are an expert in applying reasoning strategies and filling in templates."}, {"role": "user", "content": "Fill in the following template based on the given analysis and class labels:\\n\\nTemplate: {template}\\nAnalysis: {analysis}\\nClass Labels: {class_labels}\\n\\nProvide your answer as the completed template."}]
7	final_completion	[{"role": "system", "content": "You are a meta-cognitive reasoning expert capable of synthesizing information and providing insightful conclusions."}, {"role": "user", "content": "Based on the following filled template, analysis, and class labels, provide a final completion that includes:\\n1. A summary of the reasoning process\\n2. An evaluation of the strength of the conclusion\\n3. Suggestions for further investigation or alternative perspectives\\n\\nContext: {filled_template}\\nAnalysis: {analysis}\\nClass Labels: {class_labels}\\n\\nProvide your answer in a clear, structured format."}]
8	final_answer	[{"role": "system", "content": "You are a meta-cognitive reasoning expert capable of synthesizing information and providing insightful conclusions."}, {"role": "user", "content": "Below is a conversation between a user and a helpful assistant. Generate an accurate completion based on the context.\\n\\nContext: {filled_template}\\nInput: {input_data}\\nOutput:"}]
\.


--
-- Name: ai_responses_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.ai_responses_id_seq', 4, true);


--
-- Name: conversation_templates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.conversation_templates_id_seq', 8, true);


--
-- Name: ai_responses ai_responses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ai_responses
    ADD CONSTRAINT ai_responses_pkey PRIMARY KEY (id);


--
-- Name: conversation_templates conversation_templates_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.conversation_templates
    ADD CONSTRAINT conversation_templates_name_key UNIQUE (name);


--
-- Name: conversation_templates conversation_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.conversation_templates
    ADD CONSTRAINT conversation_templates_pkey PRIMARY KEY (id);


--
-- Name: ai_responses ai_response_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER ai_response_trigger BEFORE INSERT OR UPDATE ON public.ai_responses FOR EACH ROW EXECUTE FUNCTION public.update_ai_response();


--
-- PostgreSQL database dump complete
--

