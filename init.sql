-- Enable PL/Python
CREATE EXTENSION IF NOT EXISTS plpython3u;

-- Set the Python path to use our virtual environment
CREATE OR REPLACE FUNCTION set_venv_python() RETURNS void AS $$
import sys
import os

venv_path = '/opt/venv'
venv_site_packages = f'{venv_path}/lib/python3.11/site-packages'

if venv_site_packages not in sys.path:
    sys.path.insert(0, venv_site_packages)

os.environ['VIRTUAL_ENV'] = venv_path
os.environ['PATH'] = f"{venv_path}/bin:{os.environ['PATH']}"
$$ LANGUAGE plpython3u;

SELECT set_venv_python();

-- Check Python path after setting virtual environment
CREATE OR REPLACE FUNCTION check_python_path() RETURNS text AS $$
import sys
return '\n'.join(sys.path)
$$ LANGUAGE plpython3u;

-- Check Python environment
CREATE OR REPLACE FUNCTION check_python_env() RETURNS text AS $$
import sys
return sys.version
$$ LANGUAGE plpython3u;

-- Check OpenAI import
CREATE OR REPLACE FUNCTION check_openai_import() RETURNS text AS $$
try:
    import openai
    return f"OpenAI version: {openai.__version__}"
except ImportError as e:
    return str(e)
$$ LANGUAGE plpython3u;

-- Check typing_extensions
CREATE OR REPLACE FUNCTION check_typing_extensions() RETURNS text AS $$
try:
    import typing_extensions
    return f"typing_extensions version: {typing_extensions.__version__}"
except ImportError as e:
    return str(e)
except AttributeError:
    return f"typing_extensions is installed, but __version__ is not available"
$$ LANGUAGE plpython3u;

-- Create a table to store conversation templates
CREATE TABLE IF NOT EXISTS conversation_templates (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    template JSONB NOT NULL
);

-- Create a function to insert or update a conversation template
CREATE OR REPLACE FUNCTION upsert_conversation_template(p_name TEXT, p_template TEXT)
RETURNS VOID AS $$
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
$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION build_and_submit_conversation(template_name TEXT, params TEXT)
RETURNS TEXT AS $$
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
$$ LANGUAGE plpython3u;

-- Insert initial conversation templates
SELECT upsert_conversation_template(
    'simple_conversation',
    '[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Hello, my name is {name}. {question}"}
    ]'
);

SELECT upsert_conversation_template(
    'dynamic_response',
    '[
        {"role": "system", "content": "You are a helpful assistant. Respond to the following input concisely."},
        {"role": "user", "content": "{input}"}
    ]'
);

-- Create the ai_responses table
CREATE TABLE ai_responses (
    id SERIAL PRIMARY KEY,
    input_text TEXT NOT NULL,
    ai_response TEXT
);

-- Create the update_ai_response function
CREATE OR REPLACE FUNCTION update_ai_response()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

-- Create the ai_response_trigger
CREATE TRIGGER ai_response_trigger
BEFORE INSERT OR UPDATE ON ai_responses
FOR EACH ROW
EXECUTE FUNCTION update_ai_response();

-- Run checks
SELECT check_python_path();
SELECT check_python_env();
SELECT check_openai_import();
SELECT check_typing_extensions();
