#' @export
makeRLearner.classif.kerasff = function() {
  makeRLearnerClassif(
    cl = "classif.kerasff",
    package = "keras",
    par.set = makeParamSet(
      makeIntegerLearnerParam(id = "epochs", lower = 1L, default = 30L),
      makeIntegerLearnerParam(id = "early_stopping_patience", lower = 0L, default = 2L),
      makeDiscreteLearnerParam(id = "optimizer",  default = "sgd",
        values = c("sgd", "rmsprop", "adagrad", "adadelta", "adam", "nadam")),
      makeNumericLearnerParam(id = "lr", lower = 0, upper = 1, default = 0.001),
      makeNumericLearnerParam(id = "decay", lower = 0, upper = 1, default = 0),
      makeNumericLearnerParam(id = "momentum", lower = 0, upper = 1, default = 0,
        requires = quote(optimizer == "sgd")),
      makeNumericLearnerParam(id = "rho", lower = 0, upper = 1, default = 0.001,
        requires = quote(optimizer == "rmsprop")),
      makeNumericLearnerParam(id = "beta_1", lower = 0, upper = 1, default = 0.9,
        requires = quote(optimizer %in% c("adam", "nadam"))),
      makeNumericLearnerParam(id = "beta_2", lower = 0, upper = 1, default = 0.999,
        requires = quote(optimizer %in% c("adam", "nadam"))),
      makeDiscreteLearnerParam(id = "loss",
        values = c("categorical_crossentropy", "sparse_categorical_crossentropy", "binary_crossentropy"),
        default = "categorical_crossentropy"),
      makeIntegerLearnerParam(id = "batch_size", lower = 1L, upper = Inf, default = 1L),
      makeIntegerLearnerParam(id = "layers", lower = 1L, upper = 4L, default = 1L),
      makeDiscreteLearnerParam(id = "batchnorm_dropout",
        values = c("batchnorm", "dropout", "none"), default = "none"),
      makeNumericLearnerParam(id = "input_dropout_rate", default = 0, lower = 0, upper = 1, requires = quote(batchnorm_dropout == "dropout")),
      makeNumericLearnerParam(id = "dropout_rate", default = 0, lower = 0, upper = 1, requires = quote(batchnorm_dropout == "dropout")),
      # Neurons / Layers
      makeIntegerLearnerParam(id = "units_layer1", lower = 1L, default = 1L),
      makeIntegerLearnerParam(id = "units_layer2", lower = 1L, default = 1L,
        requires = quote(layers >= 2)),
      makeIntegerLearnerParam(id = "units_layer3", lower = 1L, default = 1L,
        requires = quote(layers >= 3)),
      makeIntegerLearnerParam(id = "units_layer4", lower = 1L, default = 1L,
        requires = quote(layers >= 4)),
      # Activations
      makeDiscreteLearnerParam(id = "act_layer",
        values = c("elu", "relu", "selu", "tanh", "sigmoid","PRelU", "LeakyReLu"),
        default = "relu"),
      # Initializers
      makeDiscreteLearnerParam(id = "init_layer",
        values = c("glorot_normal", "glorot_uniform", "he_normal", "he_uniform"),
        default = "glorot_uniform"),
      makeIntegerLearnerParam(id = "init_seed", lower = 1L, upper = Inf, special.vals = list(NULL)),
      # Regularizers
      makeNumericLearnerParam(id = "l1_reg_layer",
        lower = 0, upper = 1, default = 0),
      makeNumericLearnerParam(id = "l2_reg_layer",
        lower = 0, upper = 1, default = 0),
      makeNumericLearnerParam(id = "validation_split",
        lower = 0, upper = 1, default = 0),
      makeLogicalLearnerParam(id = "learning_rate_scheduler", default = FALSE),
      makeIntegerLearnerParam(id = "nthread", default = 32L, lower = 1L)
    ),
    properties = c("numerics", "prob", "twoclass", "multiclass"),
    par.vals = list(nthread = 32L),
    name = "Keras Fully-Connected NN",
    short.name = "kerasff"
  )
}


trainLearner.classif.kerasff  = function(.learner, .task, .subset, .weights = NULL,
  epochs = 100L, early_stopping_patience = 5L, learning_rate_scheduler = FALSE,
  optimizer = "adam", lr = 0.001, beta_1 = 0.9, beta_2 = 0.999, momentum = 0, decay = 0,
  rho = 0.9, loss = "categorical_crossentropy", batch_size = 128L, layers = 1,
  batchnorm_dropout = "dropout", input_dropout_rate = 0, dropout_rate = 0,
  units_layer1 = 32, units_layer2 = 32, units_layer3 = 32, units_layer4 = 32, init_layer = "glorot_uniform",
  act_layer = "relu", l1_reg_layer = 0.01, l2_reg_layer = 0.01, validation_split = 0.2, nthread = 32L,
  init_seed = NULL) {

  # Configure Keras: 2) nthread 1) seed
  Sys.setenv(TF_CPP_MIN_LOG_LEVEL="3")  # prevent unwanted output
  require("keras")
  tensorflow::tf$logging$set_verbosity(tensorflow::tf$logging$ERROR)

  if (!is.null(init_seed)) {
    # this gives some unwanted output
    reticulate::py_capture_output({
      use_session_with_seed(init_seed, disable_parallel_cpu = nthread == 1L)
    })
  }

  if (nthread > 1L) {
    K = backend()
    sess = K$tf$Session(
      config = K$tf$ConfigProto(
        intra_op_parallelism_threads = as.integer(nthread),
        inter_op_parallelism_threads = as.integer(nthread)))
    K$set_session(sess)
  }

  input_shape = getTaskNFeats(.task)
  output_shape = length(getTaskClassLevels(.task))
  data = getTaskData(.task, .subset, target.extra = TRUE)

  # https://stackoverflow.com/questions/39691902/ordering-of-batch-normalization-and-dropout
  # Dense -> Act -> [BN] -> [Dropout]
  regularizer = regularizer_l1_l2(l1 = l1_reg_layer, l2 = l2_reg_layer)
  initializer = switch(init_layer,
    "glorot_normal" = initializer_glorot_normal(),
    "glorot_uniform" = initializer_glorot_uniform(),
    "he_normal" = initializer_he_normal(),
    "he_uniform" = initializer_he_uniform()
  )
  # this gives some unwanted output
  optimizer = switch(optimizer,
    "sgd" = optimizer_sgd(lr, momentum, decay = decay),
    "rmsprop" = optimizer_rmsprop(lr, rho, decay = decay),
    "adagrad" = optimizer_adagrad(lr, decay = decay),
    "adam" = optimizer_adam(lr, beta_1, beta_2, decay = decay),
    "nadam" = optimizer_nadam(lr, beta_1, beta_2, schedule_decay = decay)
  )


  callbacks = c()
  if (early_stopping_patience > 0)
    callbacks = c(callbacks, callback_early_stopping(monitor = 'val_loss', patience = early_stopping_patience))
  if (learning_rate_scheduler)
    # https://arxiv.org/pdf/1608.03983.pdf
    # We reset the learning rate after evey n, e.g. n = 32 interations. 
    callbacks = c(callbacks, keras::callback_learning_rate_scheduler(
      function(epoch, lr) {
        restart_every_n = 24L
        restarts = floor(epoch / restart_every_n)
        epoch_since_restart = epoch - (restart_every_n * restarts)
        lr * (1 + cos((epoch_since_restart / restart_every_n) * pi))
      }
    ))

  units_layers = c(units_layer1, units_layer2, units_layer3, units_layer4)

  model = keras_model_sequential()
  if (batchnorm_dropout == "dropout")
    model = layer_dropout(model, rate = input_dropout_rate, input_shape = input_shape)

  for (i in seq_len(layers)) {
    model = layer_dense(model, units = units_layers[i], input_shape = input_shape,
        kernel_regularizer = regularizer, kernel_initializer = initializer,
        bias_regularizer = regularizer,   bias_initializer = initializer)
    model = layer_activation(model, act_layer)
    if (batchnorm_dropout == "batchnorm") model = layer_batch_normalization(model)
    if (batchnorm_dropout == "dropout")   model = layer_dropout(model, rate = dropout_rate)
  }
  model = layer_dense(model, units = output_shape, activation = 'softmax')

  compile(
    model,
    optimizer = optimizer,
    loss = loss,
    metrics = c('accuracy')
  )

  y = to_categorical(as.numeric(data$target) - 1, output_shape)

  history = fit(model, as.matrix(data$data), y,
    epochs = epochs, batch_size = batch_size,
    validation_split = validation_split,
    callbacks = callbacks, verbose = 0)  # verbose = 0 prevents a lot of unnecessary output

  list(model = model, history = history, target_levels = levels(data$target))
}

predictLearner.classif.kerasff = function(.learner, .model, .newdata, ...) {
  if (.learner$predict.type == "prob") {
    p = predict_proba(.model$learner.model$model, as.matrix(.newdata))
    colnames(p) = .model$learner.model$target_levels
  } else {
    p = predict_classes(.model$learner.model$model, as.matrix(.newdata))
    labels = .model$learner.model$target_levels[unique(p + 1)]
    p = factor(p, labels = labels)
  }
  return(p)
}
