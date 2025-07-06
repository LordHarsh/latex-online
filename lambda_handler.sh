const awsLambdaFastify = require('@fastify/aws-lambda');
const fastify = require('fastify');
const LatexOnline = require('./lib/LatexOnline');
const utils = require('./lib/utilities');

const logger = utils.logger('lambda-handler.js');

// Initialize Fastify app
const app = fastify({
  logger: false // Use custom logger instead
});

// Global variable to store initialized latexOnline instance
let latexOnline = null;

// Initialize LatexOnline service
async function initializeLatexOnline() {
  if (!latexOnline) {
    try {
      latexOnline = await LatexOnline.create('/tmp/downloads/', '/tmp/storage/');
      if (!latexOnline) {
        throw new Error('Failed to initialize latexOnline');
      }
      logger.info('LatexOnline service initialized successfully');
    } catch (error) {
      logger.error('ERROR: failed to initialize latexOnline', error);
      throw error;
    }
  }
  return latexOnline;
}

function sendError(reply, userError) {
  reply.header('Content-Type', 'text/plain');
  const statusCode = userError ? 400 : 500;
  const error = userError || 'Internal Server Error';
  reply.status(statusCode).send(error);
}

async function handleResult(reply, preparation, force, downloadName) {
  const {request, downloader, userError} = preparation;
  
  if (!request) {
    sendError(reply, userError);
    return;
  }

  let compilation = latexOnline.compilationWithFingerprint(request.fingerprint);
  
  if (force && compilation) {
    latexOnline.removeCompilation(compilation);
  }
  
  compilation = latexOnline.getOrCreateCompilation(request, downloader);
  await compilation.run();

  // Clean up downloader
  downloader.dispose();

  if (compilation.userError) {
    sendError(reply, compilation.userError);
  } else if (compilation.success) {
    if (downloadName) {
      reply.header('content-disposition', `attachment; filename="${downloadName}"`);
    }
    reply.status(200).sendFile(compilation.outputPath());
  } else {
    reply.status(400).sendFile(compilation.logPath());
  }
}

// Register the compile route
app.get('/compile', async (request, reply) => {
  try {
    // Ensure LatexOnline is initialized
    await initializeLatexOnline();

    const query = request.query;
    const forceCompilation = query && !!query.force;
    let command = query && query.command ? query.command : 'pdflatex';
    command = command.trim().toLowerCase();

    let preparation;

    if (query.text) {
      preparation = await latexOnline.prepareTextCompilation(query.text, command);
    } else if (query.url) {
      preparation = await latexOnline.prepareURLCompilation(query.url, command);
    } else if (query.git) {
      const workdir = query.workdir || '';
      preparation = await latexOnline.prepareGitCompilation(
        query.git, 
        query.target, 
        'master', 
        command, 
        workdir
      );
    }

    if (preparation) {
      await handleResult(reply, preparation, forceCompilation, query.download);
    } else {
      sendError(reply, 'ERROR: failed to parse request: ' + JSON.stringify(query));
    }
  } catch (error) {
    logger.error('Error in compile handler:', error);
    sendError(reply, 'Internal server error');
  }
});

// Health check endpoint for Lambda
app.get('/health', async (request, reply) => {
  reply.send({ status: 'ok', timestamp: new Date().toISOString() });
});

// Create the Lambda handler
const handler = awsLambdaFastify(app);

module.exports = { handler };